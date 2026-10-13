defmodule FountainWeb.FrontDoorController do
  @moduledoc """
  `/`: a self-hosted instance has no page of its own to show there, so it
  sends a person to the console. The dashboard's own auth hook turns that
  into the sign-in page for someone who is not signed in.
  """
  use FountainWeb, :controller

  def home(conn, _params), do: redirect(conn, to: ~p"/dashboard")
end
