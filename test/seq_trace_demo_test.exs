defmodule SeqTraceDemoTest do
  use ExUnit.Case

  defmodule Context do
    def set_context() do
      trace_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
      :seq_trace.set_token(:label, {:trace_id, trace_id})
    end

    def get_context() do
      case :seq_trace.get_token(:label) do
        {:label, {:trace_id, trace_id}} -> trace_id
        _ -> nil
      end
    end

    def clear_context() do
      :seq_trace.set_token([])
    end
  end

  defmodule DemoPlug do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/trace" do
      # This would be done by the instrumentation (ex: in a telemetry handler)
      Context.set_context()

      trace_id_1 =
        Task.async(fn ->
          Task.async(fn ->
            Context.get_context()
          end)
          |> Task.await()
        end)
        |> Task.await()

      # Say we want to get the context to generate outgoing HTTP
      # headers that will propagate the context
      trace_id_2 = Context.get_context()

      response = Jason.encode!(%{trace_id_1: trace_id_1, trace_id_2: trace_id_2})
      Context.clear_context()
      send_resp(conn, 200, response)
    end

    get "/trace/broken" do
      send(self(), :msg_from_the_outside)

      Context.set_context()

      trace_id_1 =
        Task.async(fn ->
          Task.async(fn ->
            Context.get_context()
          end)
          |> Task.await()
        end)
        |> Task.await()

      # This message comes in _without_ a seq_trace token
      # It clears the the token which breaks the trace
      receive do
        :msg_from_the_outside -> :ok
      end

      # Now when we try to get the context, nothing is there
      trace_id_2 = Context.get_context()

      response = Jason.encode!(%{trace_id_1: trace_id_1, trace_id_2: trace_id_2})
      Context.clear_context()
      send_resp(conn, 200, response)
    end
  end

  setup_all do
    Plug.Cowboy.http(DemoPlug, [], port: 7777)
    :ok
  end

  test "Cross process Trace ID propigation" do
    {:ok, {_, _, body}} = :httpc.request('http://localhost:7777/trace')

    %{"trace_id_1" => trace_id_1, "trace_id_2" => trace_id_2} = Jason.decode!(to_string(body))

    assert trace_id_1 == trace_id_2
  end

  test "Broken by a stray receive" do
    {:ok, {_, _, body}} = :httpc.request('http://localhost:7777/trace/broken')

    %{"trace_id_1" => trace_id_1, "trace_id_2" => trace_id_2} = Jason.decode!(to_string(body))

    # trace_id_2 will always be nil
    assert trace_id_1 == trace_id_2
  end
end
