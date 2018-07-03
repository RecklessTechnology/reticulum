defmodule Ret.MediaResolver do
  use Retry

  @ytdl_root_hosts [
    "youtube.com",
    "imgur.com",
    "instagram.com",
    "soundcloud.com",
    "tumblr.com",
    "facebook.com",
    "google.com",
    "gfycat.com",
    "flickr.com",
    "dropbox.com",
    "cloudflare.com"
  ]

  @deviant_id_regex ~r/\"DeviantArt:\/\/deviation\/([^"]+)/

  def resolve(url) when is_binary(url) do
    uri = url |> URI.parse()
    root_host = get_root_host(uri.host)
    resolve(uri, root_host)
  end

  def resolve(%URI{host: nil}, _) do
    {:commit, nil}
  end

  def resolve(%URI{} = uri, root_host) when root_host in @ytdl_root_hosts do
    ytdl_host = Application.get_env(:ret, Ret.MediaResolver)[:ytdl_host]

    if ytdl_host do
      with ytdl_format <- "best[protocol*=http]",
           encoded_url <- uri |> URI.to_string() |> URI.encode(),
           ytdl_url <-
             "#{ytdl_host}/api/play?format=#{URI.encode(ytdl_format)}&url=#{encoded_url}" do
        ytdl_resp =
          retry with: exp_backoff() |> randomize |> cap(3_000) |> expiry(7_000) do
            HTTPoison.get!(ytdl_url)
          after
            result -> result
          else
            error -> error
          end

        case ytdl_resp do
          %HTTPoison.Response{status_code: 302, headers: headers} ->
            {:commit, headers |> media_url_from_headers}

          _ ->
            resolve_non_video(uri, root_host)
        end
      end
    else
      resolve_non_video(uri, root_host)
    end
  end

  def resolve(%URI{} = uri, root_host) do
    resolve_non_video(uri, root_host)
  end

  def resolve_non_video(%URI{} = uri, "deviantart.com") do
    uri =
      case Application.get_env(:ret, Ret.MediaResolver)[:deviantart_client_id] do
        client_id when is_binary(client_id) ->
          page_resp = retry_until_200(uri |> URI.to_string())

          with deviant_id <- Regex.run(@deviant_id_regex, page_resp.body) |> Enum.at(1),
               token_host <- "https://www.deviantart.com/oauth2/token",
               api_host <- "https://www.deviantart.com/api/v1/oauth2",
               client_secret <-
                 Application.get_env(:ret, Ret.MediaResolver)[:deviantart_client_secret] do
            token_url =
              "#{token_host}?client_id=#{client_id}&client_secret=#{client_secret}&grant_type=client_credentials"

            token_resp = retry_until_200(token_url)
            token = token_resp.body |> Poison.decode!() |> Kernel.get_in(["access_token"])

            api_url = "#{api_host}/deviation/#{deviant_id}?access_token=#{token}"
            api_resp = retry_until_200(api_url)

            api_resp.body |> Poison.decode!() |> Kernel.get_in(["content", "src"]) |> URI.parse()
          end

        _ ->
          uri
      end

    {:commit, uri |> URI.to_string()}
  end

  def resolve_non_video(%URI{} = uri, "giphy.com") do
    uri =
      case Application.get_env(:ret, Ret.MediaResolver)[:giphy_api_key] do
        giphy_api_key when is_binary(giphy_api_key) ->
          with gif_id <-
                 uri.path |> String.split("/") |> List.last() |> String.split("-") |> List.last(),
               giphy_api_url <- "https://api.giphy.com/v1/gifs/#{gif_id}?api_key=#{giphy_api_key}" do
            giphy_resp = retry_until_200(giphy_api_url)

            original_image =
              giphy_resp.body |> Poison.decode!() |> Kernel.get_in(["data", "images", "original"])

            (original_image["mp4"] || original_image["url"]) |> URI.parse()
          end

        _ ->
          uri
      end

    {:commit, uri |> URI.to_string()}
  end

  def resolve_non_video(%URI{} = uri, "imgur.com") do
    # imgur_client_id = Application.get_env(:ret, Ret.MediaResolver)[:imgur_client_id]

    # if imgur_client_id != nil
    #  ytdl_resp =
    #    retry with: exp_backoff() |> randomize |> cap(3_000) |> expiry(15_000) do
    #      HTTPoison.get!(ytdl_url)
    #    after
    #      result -> result
    #    else
    #      error -> error
    #    end
    # end

    {:commit, uri |> URI.to_string()}
  end

  def resolve_non_video(%URI{} = uri, _root_host) do
    {:commit, uri |> URI.to_string()}
  end

  defp retry_until_200(url) do
    retry with: exp_backoff() |> randomize |> cap(5_000) |> expiry(10_000) do
      case HTTPoison.get!(url) do
        %{status_code: 200} = resp ->
          resp

        resp ->
          IO.inspect(resp)
          raise "API error for #{url}"
      end
    after
      result -> result
    else
      error -> error
    end
  end

  defp get_root_host(nil) do
    nil
  end

  defp get_root_host(host) do
    # Drop subdomains
    host |> String.split(".") |> Enum.slice(-2..-1) |> Enum.join(".")
  end

  defp media_url_from_headers(headers) do
    headers |> List.keyfind("Location", 0) |> elem(1)
  end
end
