defmodule Mix.Tasks.Redeliver.Build do
  require Logger
  use Mix.Task

  @shortdoc "Build a release on the build server"

  @build_server ""
  @build_user   "app"
  @git_branch   "master"
  @timeout      5_000

  def run(_args) do
    :ssh.start

    directory = File.cwd! |> Path.basename
    tarball   = "#{directory}.tar.gz"
    archive_command = "git archive --prefix #{directory}/ --format tar.gz #{@git_branch}"

    with {:ok, channel, connection} <- start_connection(@build_server, @build_user),
         {:ok, remote_file}         <- open_remote_file(channel, tarball),
         port                       <- build_port(archive_command),
         stream                     <- unfold_stream(port),
         _data                      <- write_data(channel, stream, remote_file),
         :ok                        <- :ssh_sftp.close(channel, remote_file, @timeout),
         :ok                        <- :ssh_sftp.stop_channel(channel),
         {:ok, channel}             <- :ssh_connection.session_channel(connection, @timeout),
         :success                   <- unpack_archive(connection, channel, tarball),
         :ok                        <- wait_for_closed_message(connection, channel),
         :ok                        <- :ssh.close(connection),
      do: :ok
  end

  defp start_connection(server, user) do
    Logger.info "Starting ssh connection #{user}:#{server}"
    :ssh_sftp.start_channel(
      to_charlist(server),
      silently_accept_hosts: true,
      user:                  to_charlist(user)
    )
  end

  defp open_remote_file(channel, archive_name) do
    :ssh_sftp.open(
      channel,
      to_charlist(archive_name),
      ~w[write]a,
      @timeout
    )
  end

  defp build_port(archive_command) do
    Logger.info "Building Archive"
    Port.open(
      {
        :spawn,
        archive_command
      },
      ~w[binary exit_status]a
    )
  end

  defp unfold_stream(local_port) do
    Stream.unfold(
      local_port,
      fn port ->
        receive do
          {^port, {:data, data}} ->
            {data, port}
          {^port, {:exit_status, _status}} ->
            nil
        end
      end
    )
  end

  defp write_data(channel, stream, remote_file) do
    Logger.info "Writing to remote file: #{remote_file}"
    Enum.each(
      stream,
      fn data ->
        :ok = :ssh_sftp.write(channel, remote_file, data, @timeout)
    end)
  end

  defp unpack_archive(connection, channel, remote_file) do
    Logger.info "Unpacking Archive: #{remote_file}"
    :ssh_connection.exec(
      connection,
      channel,
      to_charlist("tar xzf #{remote_file}"),
      @timeout
    )
  end

  defp wait_for_closed_message(connection, channel) do
    Stream.unfold({connection, channel}, fn {conn, chan} ->
      receive do
        {:ssh_cm, ^conn, {:closed, ^chan}} ->
          {:ok, {conn, chan}}
        {:ssh_cm, ^conn, _message} ->
          nil
      end
    end)
    |> Stream.run
  end
end

