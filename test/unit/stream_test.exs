defmodule Portals.Unit.StreamTest do
  use ExUnit.Case, async: true

  alias Portals.Stream.State

  @max_credit 1_000
  @max_frames 4

  defp new_stream(opts \\ []) do
    State.new(
      7,
      self(),
      Keyword.merge([max_credit: @max_credit, max_frames: @max_frames], opts)
    )
  end

  describe "initial state" do
    test "starts with no credit in either direction and both directions open" do
      stream = new_stream()

      assert stream.send_credit == 0
      assert stream.recv_credit == 0
      assert stream.outbound == :open
      assert stream.inbound == :open
      refute State.fully_half_closed?(stream)
    end

    test "the first grant offers the whole receive window, and only once" do
      {stream, grant} = State.grant(new_stream())
      assert grant == @max_credit
      assert stream.recv_credit == @max_credit

      assert {^stream, 0} = State.grant(stream)
    end
  end

  describe "send window" do
    test "cannot send a single byte before the peer grants credit" do
      assert {:error, :insufficient_credit} = State.charge_send(new_stream(), 1)
    end

    test "charges the full frame size and refuses to overdraw" do
      {:ok, stream} = State.add_send_credit(new_stream(), 100, 0)

      assert {:ok, stream} = State.charge_send(stream, 60)
      assert stream.send_credit == 40
      assert stream.send_frames == 1

      assert {:error, :insufficient_credit} = State.charge_send(stream, 41)
      assert {:ok, stream} = State.charge_send(stream, 40)
      assert stream.send_credit == 0
    end

    test "enforces the frame count limit independently of the byte window" do
      # Plenty of bytes, but only @max_frames unacknowledged frames.
      {:ok, stream} = State.add_send_credit(new_stream(), @max_credit, 0)

      stream =
        Enum.reduce(1..@max_frames, stream, fn _, acc ->
          {:ok, acc} = State.charge_send(acc, 1)
          acc
        end)

      assert stream.send_credit == @max_credit - @max_frames
      assert {:error, :frame_limit} = State.charge_send(stream, 1)

      # Acknowledging one frame releases exactly one slot.
      {:ok, stream} = State.add_send_credit(stream, 1, 1)
      assert {:ok, stream} = State.charge_send(stream, 1)
      assert {:error, :frame_limit} = State.charge_send(stream, 1)
    end

    test "rejects a peer that grants more credit than the documented window" do
      assert {:error, :credit_limit_exceeded} =
               State.add_send_credit(new_stream(), @max_credit + 1, 0)

      assert {:error, :credit_limit_exceeded} = State.add_send_credit(new_stream(), -1, 0)
    end

    test "refuses to send after the outbound direction is half-closed" do
      {:ok, stream} = State.add_send_credit(new_stream(), 100, 0)
      {:ok, stream} = State.half_close_outbound(stream)

      assert {:error, :outbound_closed} = State.charge_send(stream, 1)
    end
  end

  describe "receive window" do
    test "rejects inbound data the peer was never credited for" do
      assert {:error, :credit_exceeded} = State.record_inbound(new_stream(), 1)

      {stream, @max_credit} = State.grant(new_stream())
      assert {:error, :credit_exceeded} = State.record_inbound(stream, @max_credit + 1)
      assert {:ok, _} = State.record_inbound(stream, @max_credit)
    end

    test "a tiny-frame flood hits the hard frame limit while byte credit remains" do
      {stream, _} = State.grant(new_stream())

      stream =
        Enum.reduce(1..@max_frames, stream, fn _, acc ->
          {:ok, acc} = State.record_inbound(acc, 1)
          acc
        end)

      assert stream.recv_credit > 0
      assert {:error, :frame_limit} = State.record_inbound(stream, 1)
    end

    test "consumption replenishes exactly what was consumed" do
      {stream, _} = State.grant(new_stream())
      {:ok, stream} = State.record_inbound(stream, 200)
      {:ok, stream} = State.record_inbound(stream, 300)
      assert stream.recv_credit == @max_credit - 500
      assert stream.recv_frames == 2

      {stream, grant} = State.consume_inbound(stream, 200, 1)
      assert grant == 200
      assert stream.recv_frames == 1

      {stream, grant} = State.consume_inbound(stream, 300, 1)
      assert grant == 300
      assert stream.recv_credit == @max_credit
      assert stream.recv_frames == 0
      assert stream.recv_bytes == 0
    end

    test "rejects inbound data after the peer half-closed its direction" do
      {stream, _} = State.grant(new_stream())
      {:ok, stream} = State.half_close_inbound(stream)

      assert {:error, :inbound_closed} = State.record_inbound(stream, 1)
    end
  end

  describe "half-close is independent per direction" do
    test "closing outbound leaves inbound usable, and vice versa" do
      {stream, _} = State.grant(new_stream())
      {:ok, stream} = State.add_send_credit(stream, 100, 0)

      {:ok, stream} = State.half_close_outbound(stream)
      assert stream.inbound == :open
      assert {:ok, stream} = State.record_inbound(stream, 10)
      assert {:error, :outbound_closed} = State.charge_send(stream, 10)
      refute State.fully_half_closed?(stream)

      {:ok, stream} = State.half_close_inbound(stream)
      assert State.fully_half_closed?(stream)
    end

    test "half-close is idempotent in both directions" do
      {:ok, stream} = State.half_close_outbound(new_stream())
      assert :already_closed = State.half_close_outbound(stream)

      {:ok, stream} = State.half_close_inbound(stream)
      assert :already_closed = State.half_close_inbound(stream)
    end
  end

  describe "parked senders" do
    test "are drained in arrival order and released all at once on teardown" do
      stream = new_stream()
      stream = State.park_sender(stream, :first)
      stream = State.park_sender(stream, :second)

      assert {:ok, :first, stream} = State.pop_sender(stream)
      stream = State.park_sender(stream, :third)

      assert {[:second, :third], stream} = State.take_senders(stream)
      assert :empty = State.pop_sender(stream)
    end
  end
end
