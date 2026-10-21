defmodule Issho.ToolsTest do
  use ExUnit.Case, async: false

  alias Issho.{Participant, Tool, Tools, Transaction}

  @instance IsshoTest.Issho

  # An app's own model, through its API: the tools' definitions in, tool uses out, no MCP.
  setup do
    room = "board:" <> Transaction.id()
    {:ok, ken} = Issho.join_as(@instance, %{id: "user:ken", name: "Ken"}, room)
    {:ok, _} = Participant.open(ken, room)

    assistant = %{id: "assistant:ada", name: "Assistant", kind: :agent}
    ctx = Tool.Context.new(@instance, assistant, on_behalf_of: %{id: "user:ada", name: "Ada"})
    %{room: room, ken: ken, ctx: ctx}
  end

  test "the definitions are what a model's API takes" do
    [join | _] = Tools.schemas(Tools.room())

    assert %{
             "name" => "join_room",
             "description" => "Joins a room as yourself, an agent" <> _,
             "input_schema" => %{
               "type" => "object",
               "properties" => %{"room" => %{"type" => "string"}},
               "required" => ["room"]
             }
           } = join
  end

  test "a tool use runs as the app's agent, in the room, seen by the people", %{
    room: room,
    ken: ken,
    ctx: ctx
  } do
    assert {:ok, %{"you" => "assistant:ada", "people" => people}} =
             Tools.call(Tools.room(), "join_room", %{"room" => room}, ctx)

    assert %{"on_behalf_of" => "Ada", "kind" => "agent"} = Enum.find(people, & &1["you"])

    ops = [%{"op" => "set", "path" => ["title"], "value" => "Plan"}]

    assert {:ok, %{"revision" => 1}} =
             Tools.call(Tools.room(), "change_document", %{"room" => room, "ops" => ops}, ctx)

    assert_receive {Participant, ^ken, "tx", %{"event" => %{"author" => "assistant:ada"}}}
  end

  test "what is wrong with a tool use comes back in words, for the model", %{room: room, ctx: ctx} do
    assert {:error, "room is required."} = Tools.call(Tools.room(), "join_room", %{}, ctx)

    assert {:error, "status is not text of the right length."} =
             Tools.call(
               Tools.room(),
               "set_status",
               %{"room" => room, "status" => String.duplicate("x", 200)},
               ctx
             )

    assert {:error, "There is no tool \"fly\"."} = Tools.call(Tools.room(), "fly", %{}, ctx)
  end

  defmodule Sort do
    use Issho.Tool, name: "sort", description: "Sorts."

    arg :by,
        {:array,
         {:object, [{:key, :string, required: true}, {:dir, {:enum, ["asc", "desc"]}, []}]}},
        required: true

    @impl true
    def call(%{by: by}, _ctx), do: {:ok, by}
  end

  test "a list of objects comes with each object's declared fields, checked", %{ctx: ctx} do
    assert {:ok, [%{key: "total", dir: "desc"}, %{key: "name"}]} =
             Tools.run(
               Sort,
               %{"by" => [%{"key" => "total", "dir" => "desc", "x" => 1}, %{"key" => "name"}]},
               ctx
             )

    # A field given as null is not given, as an argument is not.
    assert {:ok, [%{key: "name"} = sort]} =
             Tools.run(Sort, %{"by" => [%{"key" => "name", "dir" => nil}]}, ctx)

    refute Map.has_key?(sort, :dir)

    assert {:error, "by is not a list of an object with key."} =
             Tools.run(Sort, %{"by" => [%{"dir" => "asc"}]}, ctx)

    assert {:error, _} = Tools.run(Sort, %{"by" => [%{"key" => "a", "dir" => "up"}]}, ctx)
  end
end
