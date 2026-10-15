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

  def format_date(nil), do: ""
  def format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  def format_ts(nil), do: ""
  def format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
