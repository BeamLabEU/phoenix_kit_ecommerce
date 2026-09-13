defmodule PhoenixKitEcommerce.Services.ImageDownloaderTest do
  @moduledoc """
  `PhoenixKitEcommerce.Services.ImageDownloader`'s request shaping and
  body bounding: `pinned_request/2` (connect to the address the SSRF
  guard validated, keep the hostname for TLS/Host) and `download_image/2`'s
  streaming size limit. HTTP goes through `Req.Test`'s plug adapter
  (`opts[:req_options]`), never the network; the URLs use a PUBLIC
  literal address so the private-range guard passes with no DNS lookup.
  `DataCase` only for the sandbox `Policy` reads its setting through.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Services.ImageDownloader

  @stub __MODULE__
  @url "https://93.184.216.34/images/pic.png"

  defp opts(extra \\ []), do: [req_options: [plug: {Req.Test, @stub}]] ++ extra

  defp png(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("image/png")
    |> Plug.Conn.send_resp(200, body)
  end

  describe "pinned_request/2" do
    test "a nil pin leaves the URL and options untouched" do
      assert ImageDownloader.pinned_request("https://cdn.example.com/a.jpg", nil) ==
               {"https://cdn.example.com/a.jpg", []}
    end

    test "connects to the validated address, keeps the hostname for SNI and the Host header" do
      assert {url, opts} =
               ImageDownloader.pinned_request(
                 "https://cdn.example.com/a.jpg?w=1",
                 {93, 184, 216, 34}
               )

      assert url == "https://93.184.216.34/a.jpg?w=1"
      assert opts[:connect_options] == [hostname: "cdn.example.com"]
      assert opts[:headers] == [{"host", "cdn.example.com"}]
    end

    test "a non-default port stays in the Host header" do
      assert {"https://93.184.216.34:8443/a.jpg", opts} =
               ImageDownloader.pinned_request(
                 "https://cdn.example.com:8443/a.jpg",
                 {93, 184, 216, 34}
               )

      assert opts[:headers] == [{"host", "cdn.example.com:8443"}]
    end

    test "an IPv6 address is bracketed in the URL" do
      assert {"https://[2606:4700::1]/a.jpg", opts} =
               ImageDownloader.pinned_request(
                 "https://cdn.example.com/a.jpg",
                 {0x2606, 0x4700, 0, 0, 0, 0, 0, 1}
               )

      assert opts[:connect_options] == [hostname: "cdn.example.com"]
    end
  end

  describe "download_image/2 — size limit" do
    test "a body under the limit is written to a temp file" do
      Req.Test.stub(@stub, fn conn -> png(conn, "png-bytes") end)

      assert {:ok, path, "image/png", 9} = ImageDownloader.download_image(@url, opts())
      assert File.read!(path) == "png-bytes"
      File.rm(path)
    end

    test "a content-length past the limit is refused" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-length", "1000")
        |> png(conn_body_under_limit())
      end)

      assert {:error, {:file_too_large, message}} =
               ImageDownloader.download_image(@url, opts(max_bytes: 100))

      assert message =~ "exceeds limit"
    end

    test "a streamed body is halted once it passes the limit" do
      Req.Test.stub(@stub, fn conn ->
        conn = conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_chunked(200)

        Enum.reduce(1..5, conn, fn _, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("x", 40))
          conn
        end)
      end)

      assert {:error, {:file_too_large, _}} =
               ImageDownloader.download_image(@url, opts(max_bytes: 100))
    end

    test "a streamed body within the limit is reassembled whole" do
      Req.Test.stub(@stub, fn conn ->
        conn = conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_chunked(200)
        {:ok, conn} = Plug.Conn.chunk(conn, "ab")
        {:ok, conn} = Plug.Conn.chunk(conn, "cd")
        conn
      end)

      assert {:ok, path, "image/png", 4} =
               ImageDownloader.download_image(@url, opts(max_bytes: 100))

      assert File.read!(path) == "abcd"
      File.rm(path)
    end

    test "the content type is still validated on the final response" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, "<html>")
      end)

      assert {:error, {:invalid_content_type, "text/html"}} =
               ImageDownloader.download_image(@url, opts())
    end
  end

  defp conn_body_under_limit, do: "tiny"
end
