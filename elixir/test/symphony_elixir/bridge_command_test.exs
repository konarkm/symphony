defmodule SymphonyElixir.BridgeCommandTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{BridgeCommand, Comment}

  test "parses only explicit top-level symphony commands" do
    assert {:ok, %{action: :status, args: ""}} =
             BridgeCommand.parse(%Comment{id: "c1", body: "symphony status", author_name: "Konark"})

    assert {:ok, %{action: :pause}} =
             BridgeCommand.parse(%Comment{id: "c2", body: "  Symphony   pause  ", author_name: "Konark"})

    assert {:ok, %{action: :retry, args: "now please"}} =
             BridgeCommand.parse(%Comment{id: "c2b", body: "symphony retry now please", author_name: "Konark"})

    assert {:ok, %{action: :help}} =
             BridgeCommand.parse(%Comment{id: "c3", body: "symphony", author_name: "Konark"})

    assert :not_command =
             BridgeCommand.parse(%Comment{id: "c3b", body: "sym", author_name: "Konark"})

    assert :not_command =
             BridgeCommand.parse(%Comment{id: "c4", body: "can symphony status this?", author_name: "Konark"})

    assert :not_command =
             BridgeCommand.parse(%Comment{id: "c5", body: "symphonystatus", author_name: "Konark"})

    assert :not_command =
             BridgeCommand.parse(%Comment{id: "c6", body: "symphony status", parent_id: "parent", author_name: "Konark"})

    assert :not_command =
             BridgeCommand.parse(%Comment{id: "c7", body: "symphony status", author_is_bot: true})

    assert :not_command = BridgeCommand.parse(:not_a_comment)
    refute BridgeCommand.command?(:not_a_comment)
  end

  test "unknown explicit commands are handled without becoming agent context" do
    comment = %Comment{id: "c1", body: "symphony frobnicate", author_name: "Konark"}

    assert {:error, :unknown_command, "frobnicate"} = BridgeCommand.parse(comment)
    assert BridgeCommand.command?(comment)
    assert BridgeCommand.help_text() =~ "symphony status"
  end
end
