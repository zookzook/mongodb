defmodule Mongo.Protocol do
  @moduledoc false

  use DBConnection
  use Mongo.Messages
  alias Mongo.Protocol.Utils

  @timeout        5000
  @find_flags     ~w(tailable_cursor slave_ok no_cursor_timeout await_data exhaust allow_partial_results oplog_replay)a
  @find_one_flags ~w(slave_ok exhaust partial)a
  @insert_flags   ~w(continue_on_error)a
  @update_flags   ~w(upsert)a
  @write_concern  ~w(w j wtimeout)a

  def disconnect(_error, %{socket: {mod, sock}} = s) do
    notify_disconnect(s)
    mod.close(sock)
  end

  defp notify_disconnect(%{connection_type: type, topology_pid: pid, host: host}) do
    GenServer.cast(pid, {:disconnect, type, host})
  end

  def connect(opts) do
    {write_concern, opts} = Keyword.split(opts, @write_concern)
    write_concern = Keyword.put_new(write_concern, :w, 1)

    state = %{
      socket: nil,
      request_id: 0,
      timeout: opts[:timeout] || @timeout,
      connect_timeout_ms: opts[:connect_timeout_ms] || @timeout,
      database: Keyword.fetch!(opts, :database),
      write_concern: Map.new(write_concern),
      wire_version: nil,
      auth_mechanism: opts[:auth_mechanism] || nil,
      connection_type: Keyword.fetch!(opts, :connection_type),
      topology_pid: Keyword.fetch!(opts, :topology_pid),
      ssl: opts[:ssl] || false
    }

    connect(opts, state)
  end

  defp connect(opts, s) do
    result =
      with {:ok, s} <- tcp_connect(opts, s),
           {:ok, s} <- maybe_ssl(opts, s),
           {:ok, s} <- wire_version(s),
           {:ok, s} <- maybe_auth(opts, s) do

        {mod, sock} = s.socket
        :ok = setopts(mod, sock, active: :once)

        {:ok, s}
      end

    case result do
      {:ok, s} ->
        {:ok, s}
      {:disconnect, reason, s} ->
        reason = case reason do
          {:tcp_recv, reason} -> Mongo.Error.exception(tag: :tcp, action: "recv", reason: reason, host: s.host)
          {:tcp_send, reason} -> Mongo.Error.exception(tag: :tcp, action: "send", reason: reason, host: s.host)
          %Mongo.Error{} = reason -> reason
        end
        {mod, sock} = s.socket
        mod.close(sock)
        {:error, reason}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_auth(opts, s) do
    if opts[:skip_auth] do
      {:ok, s}
    else
      Mongo.Auth.run(opts, s)
    end
  end

  defp maybe_ssl(opts, s) do
    if s.ssl do
      ssl(s, opts)
    else
      {:ok, s}
    end
  end
  defp ssl(%{socket: {:gen_tcp, sock}} = s, opts) do
    host      = (opts[:hostname] || "localhost") |> to_charlist
    ssl_opts = Keyword.put_new(opts[:ssl_opts] || [], :server_name_indication, host)
    case :ssl.connect(sock, ssl_opts, s.connect_timeout_ms) do
      {:ok, ssl_sock} ->
        {:ok, %{s | socket: {:ssl, ssl_sock}}}
      {:error, reason} ->
        :gen_tcp.close(sock)
        {:error, Mongo.Error.exception(tag: :ssl, action: "connect", reason: reason, host: s.host)}
    end
  end

  defp tcp_connect(opts, s) do
    host      = (opts[:hostname] || "localhost") |> to_charlist
    port      = opts[:port] || 27017
    sock_opts = [:binary, active: false, packet: :raw, nodelay: true]
                ++ (opts[:socket_options] || [])

    s = Map.put(s, :host, "#{host}:#{port}")

    case :gen_tcp.connect(host, port, sock_opts, s.connect_timeout_ms) do
      {:ok, socket} ->
        # A suitable :buffer is only set if :recbuf is included in
        # :socket_options.
        {:ok, [sndbuf: sndbuf, recbuf: recbuf, buffer: buffer]} =
          :inet.getopts(socket, [:sndbuf, :recbuf, :buffer])
        buffer = buffer |> max(sndbuf) |> max(recbuf)
        :ok = :inet.setopts(socket, buffer: buffer)

        {:ok, %{s | socket: {:gen_tcp, socket}}}

      {:error, reason} ->
        {:error, Mongo.Error.exception(tag: :tcp, action: "connect", reason: reason, host: s.host)}
    end
  end

  defp wire_version(state) do
    # wire version
    # https://github.com/mongodb/mongo/blob/master/src/mongo/db/wire_version.h
    case Utils.command(-1, [ismaster: 1], state) do
      {:ok, %{"ok" => ok, "maxWireVersion" => version}} when ok == 1 ->  {:ok, %{state | wire_version: version}}
      {:ok, %{"ok" => ok}} when ok == 1 ->  {:ok, %{state | wire_version: 0}}
      {:ok, %{"ok" => ok, "errmsg" => msg, "code" => code}} when ok == 0 ->
        err = Mongo.Error.exception(message: msg, code: code)
        {:disconnect, err, state}
      {:disconnect, _, _} = error ->   error
    end
  end

  def handle_info({:tcp, data}, s) do
    err = Mongo.Error.exception(message: "unexpected async recv: #{inspect data}")
    {:disconnect, err, s}
  end

  def handle_info({:tcp_closed, _}, s) do
    err = Mongo.Error.exception(tag: :tcp, action: "async recv", reason: :closed, host: s.host)
    {:disconnect, err, s}
  end

  def handle_info({:tcp_error, _, reason}, s) do
    err = Mongo.Error.exception(tag: :tcp, action: "async recv", reason: reason, host: s.host)
    {:disconnect, err, s}
  end

  def handle_info({:ssl_closed, _}, s) do
    err = Mongo.Error.exception(tag: :ssl, action: "async recv", reason: :closed, host: s.host)
    {:disconnect, err, s}
  end

  def checkout(%{socket: {mod, sock}} = s) do
    case setopts(mod, sock, [active: :false]) do
      :ok                       -> recv_buffer(s)
      {:error, _} =             err -> err
    end
  end

  defp recv_buffer(%{socket: {:gen_tcp, sock}} = s) do
    receive do
      {:tcp, ^sock, _buffer} ->
        {:ok, s}
    after
      0 ->
        {:ok, s}
    end
  end
  defp recv_buffer(%{socket: {:ssl, sock}} = s) do
    receive do
      {:ssl, ^sock, _buffer} ->
        {:ok, s}
    after
      0 ->
        {:ok, s}
    end
  end

  def checkin(%{socket: {mod, sock}} = s) do
    :ok = setopts(mod, sock, [active: :once])
    {:ok, s}
  end

  def handle_execute_close(query, params, opts, s) do
    handle_execute(query, params, opts, s)
  end

  def handle_execute(%Mongo.Query{action: action, extra: extra}, params, opts, original_state) do
    {mod, sock} = original_state.socket
    :ok = setopts(mod, sock, active: false)
    tmp_state = %{original_state | database: Keyword.get(opts, :database, original_state.database)}
    with {:ok, reply, tmp_state} <- handle_execute(action, extra, params, opts, tmp_state) do
      :ok = setopts(mod, sock, active: :once)
      {:ok, reply, Map.put(tmp_state, :database, original_state.database)}
    end
  end

  defp handle_execute(:wire_version, _, _, _, state) do
    {:ok, state.wire_version, state}
  end

  defp handle_execute(:delete_one, coll, [query], opts, s) do
    flags = [:single]
    op    = op_delete(coll: Utils.namespace(coll, s, opts[:database]), query: query, flags: flags)
    message_gle(-13, op, opts, s)
  end

  defp handle_execute(:delete_many, coll, [query], opts, s) do
    flags = []
    op = op_delete(coll: Utils.namespace(coll, s, opts[:database]), query: query, flags: flags)
    message_gle(-14, op, opts, s)
  end

  defp handle_execute(:replace_one, coll, [query, replacement], opts, s) do
    flags  = flags(Keyword.take(opts, @update_flags))
    op     = op_update(coll: Utils.namespace(coll, s, opts[:database]), query: query, update: replacement,
                       flags: flags)
    message_gle(-15, op, opts, s)
  end

  defp handle_execute(:update_one, coll, [query, update], opts, s) do
    flags  = flags(Keyword.take(opts, @update_flags))
    op     = op_update(coll: Utils.namespace(coll, s, opts[:database]), query: query, update: update,
                       flags: flags)
    message_gle(-16, op, opts, s)
  end

  defp handle_execute(:update_many, coll, [query, update], opts, s) do
    flags  = [:multi | flags(Keyword.take(opts, @update_flags))]
    op     = op_update(coll: Utils.namespace(coll, s, opts[:database]), query: query, update: update,
                       flags: flags)
    message_gle(-17, op, opts, s)
  end

  defp handle_execute(:command, nil, [query], opts, s) do
    flags = Keyword.take(opts, @find_one_flags)

    # todo: Post(coll: Utils.namespace("$cmd", s, opts[:database]), query: query, select: "",
    #             num_skip: 0, num_return: 1, flags: flags(flags))
    # |> get_response(state)
    op_query(coll: Utils.namespace("$cmd", s, opts[:database]), query: query, select: "", num_skip: 0, num_return: 1, flags: flags(flags))
    |> get_response(s)
  end

  defp get_response(op, state) do
    with {:ok, response} <- Utils.post_request(state.request_id, op, state),
         state = %{state | request_id: state.request_id + 1},
         do: {:ok, response, state}
  end

  defp flags(flags) do
    Enum.reduce(flags, [], fn
      {flag, true},   acc -> [flag|acc]
      {_flag, false}, acc -> acc
    end)
  end

  defp message_gle(id, op, opts, s) do
    write_concern = Keyword.take(opts, @write_concern) |> Map.new
    write_concern = Map.merge(s.write_concern, write_concern)

    if write_concern.w == 0 do
      with :ok <- Utils.send(id, op, s), do: {:ok, :ok, s}
    else
      command = BSON.Encoder.document([{:getLastError, 1}|Map.to_list(write_concern)])
      gle_op = op_query(coll: Utils.namespace("$cmd", s, opts[:database]), query: command,
                        select: "", num_skip: 0, num_return: -1, flags: [])

      ops = [{id, op}, {s.request_id, gle_op}]
      get_response(ops, s)
    end
  end

  def ping(%{wire_version: wire_version, socket: {mod, sock}} = s) do
    {:ok, active} = getopts(mod, sock, [:active])
    :ok = setopts(mod, sock, [active: false])
    with {:ok, %{wire_version: ^wire_version}} <- wire_version(s),
         :ok = setopts(mod, sock, active),
         do: {:ok, s}
  end

  defp setopts(:gen_tcp, sock, opts), do: :inet.setopts(sock, opts)
  defp setopts(:ssl, sock, opts), do: :ssl.setopts(sock, opts)

  defp getopts(:gen_tcp, sock, opts), do: :inet.getopts(sock, opts)
  defp getopts(:ssl, sock, opts), do: :ssl.getopts(sock, opts)
end
