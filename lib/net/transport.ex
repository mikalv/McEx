defmodule McEx.Net.Connection.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  def serve_socket(supervisor, socket) do
    Supervisor.start_child(supervisor, [fn -> McEx.Net.Connection.start_serve(socket) end])
  end

  def init(:ok) do
    children = [
      worker(Task, [], restart: :temporary)
    ]

    opts = [
      strategy: :simple_one_for_one,
    ]
    supervise(children, opts)
  end
end

defmodule McEx.Net.HandlerUtils do
  defmacro __using__(_opts) do
    quote do
      alias McEx.Net.Packets.Client
      alias McEx.Net.Packets.Server
      alias McEx.Net.Crypto
      alias McEx.Net.Connection.Read.State
      import McEx.Net.Connection.Read, only: [write_packet: 2 , read_packet: 1, set_encr: 2, set_compression: 2]
    end
  end
end


defmodule McEx.Net.Connection do
  alias McEx.Net.Packets.Client
  alias McEx.Net.Packets.Server
  alias McEx.Net.Crypto
  require Logger

  defmodule ClosedError do
    defexception []
  end

  def start_serve(socket) do
    {:ok, write_pid} = Task.start(McEx.Net.Connection.Write, :start_write, [socket])
    Process.monitor(write_pid)
    {:ok, read_pid} = Task.start(McEx.Net.Connection.Read, :start_read, [socket, write_pid, self])
    Process.monitor(read_pid)

    close_loop(socket, {read_pid, write_pid})
  end
  def close_loop(socket, {read, write}) do
    receive do
      {:die_with, pid} -> 
        Process.monitor(pid)
      {:DOWN, _ref, :process, _pid, _error} ->
        Process.exit(read, :disconnect)
        Process.exit(write, :disconnect)
        :gen_tcp.close(socket)
        exit(:normal)
    end
    close_loop(socket, {read, write})
  end

  defmodule Write do
    def start_write(socket) do
      try do
        write_loop(socket, nil, nil)
      rescue
        _ in ClosedError -> nil
      end
    end
    def write_loop(socket, encr_data, compr_threshold) do
      receive do
        #{:write, data} -> 
        #  encr_data = write_loop_write(socket, encr_data, data)
        #  write_loop(socket, encr_data, compr_threshold)
        {:write_struct, struct} ->
          packet_data = try do
            Server.write_packet(struct)
          rescue
            x ->
              Logger.error(Exception.format(:error, x) <> "When encoding packet:\n" <> inspect(struct) <> "\n")
              exit(:shutdown)
          end
          data = construct_packet(packet_data, compr_threshold)
          #<<McEx.DataTypes.Encode.varint(byte_size(packet_data))::binary, packet_data::binary>>
          encr_data = write_loop_write(socket, encr_data, data)
          write_loop(socket, encr_data, compr_threshold)
        {:set_encr, encr_data} ->
          write_loop(socket, encr_data, compr_threshold)
        {:set_compression, threshold} ->
          write_loop(socket, encr_data, threshold)
      end
    end

    def construct_packet(packet_data, nil) do
      [McEx.DataTypes.Encode.varint(byte_size(packet_data)), packet_data]
    end
    def construct_packet(packet_data, compr_threshold) when byte_size(packet_data) > compr_threshold do
      data_size = McEx.DataTypes.Encode.varint(byte_size(packet_data))
      compressed = deflate(packet_data)
      total_length = McEx.DataTypes.Encode.varint(byte_size(data_size) + IO.iodata_length(compressed))
      [total_length, data_size, compressed]
    end
    def construct_packet(packet_data, _) do
      [McEx.DataTypes.Encode.varint(byte_size(packet_data) + 1), 0, packet_data]
    end

    def deflate(data) do
      # TODO: Reuse zstream
      z = :zlib.open
      :zlib.deflateInit(z)
      compr = :zlib.deflate(z, data, :finish)
      :zlib.deflateEnd(z)
      :zlib.close(z)
      compr
    end

    def write_loop_write(socket, nil, data) do
      write_loop_send(socket, data)
      nil
    end
    def write_loop_write(socket, encr, data) do
      data = IO.iodata_to_binary(data)
      {encr, ciphertext}  = Crypto.encrypt(data, encr)
      write_loop_send(socket, ciphertext)
      encr
    end
    def write_loop_send(socket, data) do
      case :gen_tcp.send(socket, data) do
        :ok -> nil
        _ -> raise ClosedError
      end
    end

    def write_packet(write_process, struct) do
      send write_process, {:write_struct, struct}
    end
  end

  defmodule Read do
    defmodule State do
      defstruct socket: nil, 
      compression: nil,
      write: nil,
      player: nil,
      socket_manager: nil,
      mode: :init, 
      in_encryption: nil,
      shared_secret: nil,
      auth_init_data: nil, 
      name: nil,
      user: {false, nil, nil}, #{authed, name, uuid}
      entity_id: nil #assigned after EncryptionResponse

      def set_mode(%State{} = state, mode) when mode in [:init, :status, :login, :play] do
        %{state | mode: mode}
      end
    end

    def set_encr(%State{write: write} = state, encr) do
      send write, {:set_encr, encr}
      %{state | in_encryption: encr}
    end
    def set_compression(%State{write: write} = state, threshold) do
      send write, {:set_compression, threshold}
      %{state | compression: threshold}
    end

    def start_read(socket, write, socket_manager) do
      try do
        read_loop(%State{socket: socket, write: write, socket_manager: socket_manager})
      rescue
        _ in ClosedError -> nil
      end
    end
    def read_loop(state) do
      {state, data} = read_packet(state)
      state = McEx.Net.Handlers.handle_packet(state, data)
      read_loop(state)
    end

    def read_data(socket, length) do
      case :gen_tcp.recv(socket, length) do
        {:ok, data} -> data
        _ -> raise ClosedError
      end
    end
    def read(%State{socket: socket, in_encryption: nil} = state, length) do
      data = read_data(socket, length)
      {state, data}
    end
    def read(%State{socket: socket, in_encryption: enc} = state, length) do
      enc_data = read_data(socket, length)
      {enc, data} = Crypto.decrypt(enc_data, enc)
      {%{state | in_encryption: enc}, data}
    end

    def read_packet(%State{mode: mode, compression: nil} = state) do
      {state, packet_length} = McEx.DataTypes.Decode.Util.transport_read_varint(state)
      {state, data} = read(state, packet_length)
      {state, Client.read_packet(data, mode)}
    end
    def read_packet(%State{mode: mode, compression: threshold} = state) do
      {state, data_length} = McEx.DataTypes.Decode.Util.transport_read_varint(state)
      {state, packet_length} = McEx.DataTypes.Decode.Util.transport_read_varint(state)
      if packet_length == 0 do
        {state, data} = read(state, data_length - 1)
        {state, Client.read_packet(data, mode)}
      else
        {state, data} = read(state, data_length - byte_size(McEx.DataTypes.Encode.varint(packet_length)))
        infl = inflate(data)
        {state, Client.read_packet(infl, mode)}
      end
    end

    def inflate(data) do
      z = :zlib.init
      :zlib.inflateInit(z)
      infl = :zlib.inflate(z, data)
      :zlib.inflateEnd(z)
      :zlib.close(z)
      infl
    end

    def write_packet(%State{write: write} = state, struct) do
      McEx.Net.Connection.Write.write_packet(write, struct)
      state
    end
  end

  def server_list_response do
    Poison.encode!(%{
      version: %{
        name: "1.8.7",
        protocol: 47
      },
      players: %{
        max: 100,
        online: 0,
      },
      description: %{
        text: "Test server in elixir!"
      },
      favicon: McEx.Favicon.test
    })
  end

end

