defmodule FountainWeb.AdminLive.Helpers do
  @moduledoc """
  Formatting and badge-color helpers shared by the admin LiveViews.

  Extracted from `AdminLive.Index` when the per-user and per-conversation
  detail views arrived (#446) so the three pages render dates and status
  badges identically.
  """

  def sandbox_status_color("running"), do: "bg-blue-100 text-blue-800 border-blue-200"
  def sandbox_status_color("ready"), do: "bg-green-100 text-green-800 border-green-200"
  def sandbox_status_color("suspended"), do: "bg-sky-100 text-sky-800 border-sky-200"
  def sandbox_status_color("failed"), do: "bg-red-100 text-red-700 border-red-200"

  def sandbox_status_color(_),
    do: "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)] border-[var(--color-border)]"

  def conversation_status_color("running"), do: "bg-blue-100 text-blue-800 border-blue-200"
  def conversation_status_color("completed"), do: "bg-green-100 text-green-800 border-green-200"
  def conversation_status_color("failed"), do: "bg-red-100 text-red-700 border-red-200"

  def conversation_status_color(_),
    do: "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)] border-[var(--color-border)]"

  def invoice_status_color("paid"), do: "bg-green-100 text-green-800 border-green-200"
  def invoice_status_color("open"), do: "bg-blue-100 text-blue-800 border-blue-200"
  def invoice_status_color("uncollectible"), do: "bg-red-100 text-red-700 border-red-200"

  def invoice_status_color(_),
    do: "bg-[var(--color-bg-2)] text-[var(--color-text-secondary)] border-[var(--color-border)]"

  def format_date(nil), do: ""
  def format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  def format_ts(nil), do: ""
  def format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @doc """
  A duration in hours, at the precision an operator can act on: minutes below
  an hour, one decimal of hours below two days, days above that.

  Lived as a private copy in three admin pages, which is one definition too
  many for a number that appears on all of them side by side.
  """
  def format_hours(h) when h < 1, do: "#{round(h * 60)}m"
  def format_hours(h) when h < 48, do: "#{Float.round(h * 1.0, 1)}h"
  def format_hours(h), do: "#{Float.round(h / 24, 1)}d"

  @doc """
  The fraction of a sandbox's awake time that had no turn in flight.

  Zero rather than a division error when nothing was awake: a provider with no
  time this month is not 100% idle, it is absent.
  """
  def idle_share(%{active_seconds: 0}), do: 0.0
  def idle_share(%{active_seconds: active, idle_seconds: idle}), do: idle / active
end
