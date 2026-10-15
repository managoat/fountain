defmodule FountainWeb.AdminLive.Helpers do
  @moduledoc """
  Formatting and badge-color helpers shared by the admin LiveViews.

  Extracted from `AdminLive.Index` when the per-user and per-conversation
  detail views arrived (#446) so the three pages render dates and status
  badges identically.
  """

  # Badge colors come from the design tokens, so they follow the theme; each
  # status a page can show gets a color no other status on it shares.
  @info "bg-[var(--color-info-bg)] text-[var(--color-info-text)] border-[var(--color-info)]"
  @success "bg-[var(--color-success-bg)] text-[var(--color-success-text)] border-[var(--color-success)]"
  @warning "bg-[var(--color-warning-bg)] text-[var(--color-warning-text)] border-[var(--color-warning)]"
  @error "bg-[var(--color-error-bg)] text-[var(--color-error-text)] border-[var(--color-error)]"
  @neutral "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)] border-[var(--color-border)]"
  @parked "bg-[var(--color-bg-3)] text-[var(--color-text-primary)] border-[var(--color-border-strong)]"

  @doc "The warning badge, for a label that calls for attention (an admin role, a busy machine)."
  def warning_badge_color, do: @warning

  @doc "The neutral badge, for a label that does not."
  def neutral_badge_color, do: @neutral

  def sandbox_status_color("starting"), do: @info
  def sandbox_status_color("ready"), do: @success
  def sandbox_status_color("suspended"), do: @parked
  def sandbox_status_color("failed"), do: @error
  def sandbox_status_color(_), do: @neutral

  # Conversations and their turns share this: `idle` and `completed` are each
  # one of their resting states, `interrupted` is a turn's.
  def conversation_status_color("running"), do: @info
  def conversation_status_color("idle"), do: @success
  def conversation_status_color("completed"), do: @success
  def conversation_status_color("interrupted"), do: @warning
  def conversation_status_color("failed"), do: @error
  def conversation_status_color(_), do: @neutral

  def format_date(nil), do: ""
  def format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  def format_ts(nil), do: ""
  def format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
