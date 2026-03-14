defmodule ExAutoresearchWeb.ExportController do
  use ExAutoresearchWeb, :controller

  alias ExAutoresearch.Campaigns.Exporter

  def campaign(conn, %{"tag" => tag}) do
    case Exporter.export_zip(tag) do
      {:ok, zip_binary} ->
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="campaign-#{tag}.zip"))
        |> send_resp(200, zip_binary)

      {:error, :not_found} ->
        conn |> put_status(404) |> text("Campaign not found")

      {:error, reason} ->
        conn |> put_status(500) |> text("Export failed: #{inspect(reason)}")
    end
  end
end
