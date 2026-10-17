defmodule Fountain.TelemetrySamplerTest do
  use ExUnit.Case, async: true

  require OpenTelemetry.Tracer, as: Tracer

  @sampler :otel_sampler.new({:parent_based, %{root: {Fountain.TelemetrySampler, %{}}}})

  defp decide(ctx, name) do
    {decision, _attributes, _tracestate} =
      :otel_sampler.should_sample(
        @sampler,
        ctx,
        :otel_id_generator.generate_trace_id(),
        [],
        name,
        :client,
        %{}
      )

    decision
  end

  test "a query span with no parent is dropped" do
    assert decide(:otel_ctx.new(), "fountain.repo.query:users") == :drop
    assert decide(:otel_ctx.new(), "fountain.repo.query") == :drop
  end

  test "any other root span is sampled" do
    assert decide(:otel_ctx.new(), "fountain.fresh_provision") == :record_and_sample
    assert decide(:otel_ctx.new(), "fountain.turn") == :record_and_sample
  end

  test "a query span inside a sampled trace is kept" do
    Tracer.with_span "fountain.turn" do
      assert decide(:otel_ctx.get_current(), "fountain.repo.query:users") == :record_and_sample
    end
  end
end
