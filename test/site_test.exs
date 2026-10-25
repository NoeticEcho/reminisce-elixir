# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.SiteTest do
  # The documentation site (_config.yml): its design is the organisation's,
  # byte for byte (assets/site/README.md), its navigation leads to pages, and
  # none of it is in the Hex package.
  use ExUnit.Case, async: true

  # The SHA-256 of each file of assets/site/ as the organisation's site ships
  # it. A file updated from there gets its new SHA-256 here; a file edited
  # here fails this test.
  @design %{
    "css/fonts.css" => "f07f9f0456cba697f1a53c2c993a51cb28c36b7aaffc0df8fbdb9fc39b2e83dd",
    "css/site.css" => "d847548a36288d63a8389a034a8b78e823fd48a0b9f35aed0e514d687a91c78e",
    "css/tokens/base.css" => "220293dcc1dd72300160baf8eb21bc34a49711887dd075eb8974249c1bfe59b3",
    "css/tokens/colors.css" => "c98732f29688e99f32d63704bcd1ae90a2b0df460edecbc5f340c231d878675d",
    "css/tokens/spacing.css" =>
      "5e4e569db39424166f5308edd908066b66f71854f7d30e9b42d226b61f11c04d",
    "css/tokens/typography.css" =>
      "6d0a9ec81063a51517ff11ec37bd6983747df215faf0529592da51ccfdc4dd61",
    "fonts/LICENSE.txt" => "0ebf63e6abc8f48a9883ab74f14afe51e038668272a1956329f315511dacc570",
    "fonts/ibm-plex-sans-400-latin.woff2" =>
      "e2291e842cf5af167122a22881a740c7f2dda7716f1e8cd76680264f4a859470",
    "fonts/jetbrains-mono-400-latin.woff2" =>
      "83c005d49d8a6a50474c73a5a36ac0468076e9c4a29da7bdb14995d80560a5be",
    "fonts/literata-400-latin.woff2" =>
      "fde3d14f78c3431ee5e2f676a46dd18a1dd48ee4d0a71cc76c751f9e6f76f58e",
    "fonts/literata-400i-latin.woff2" =>
      "1e98bfbbb4eb8177b9c21b3fd526e1118c4835d21ff870c0d1c25b1ef4409fba",
    "images/apple-touch-icon.png" =>
      "bb17060aa6c07362b0a9105730a4aaf8b835e96dcbacfd8e9fef1d074f897bb3",
    "images/favicon.png" => "c9903423aefb144876c9a871d4a6ec58f632677aba8dc50798ebea250a985dea",
    "images/favicon.svg" => "2d1746e69d95cfe8e5cc2e1687666df0234d8dba88bf3b6f5aaccf0edd421419",
    "theme.js" => "eb353f4999e2227df868b4014f1998778a6ae704c778360655918ec9dbceb4fe"
  }

  @site ~w(_config.yml _data _includes _layouts 404.html assets)

  test "the design is the organisation's, byte for byte" do
    files =
      for path <- Path.wildcard("assets/site/**", match_dot: true),
          File.regular?(path),
          path != "assets/site/README.md",
          do: Path.relative_to(path, "assets/site")

    assert Enum.sort(files) == Enum.sort(Map.keys(@design))

    for {path, sha} <- @design do
      got = :crypto.hash(:sha256, File.read!(Path.join("assets/site", path)))

      assert Base.encode16(got, case: :lower) == sha,
             "assets/site/#{path} is not the organisation's"
    end
  end

  test "every file the pages load is there" do
    used =
      for path <- Path.wildcard("_includes/*.html") ++ ["_layouts/default.html"],
          [_, asset] <- Regex.scan(~r{'/(assets/site/[^']+)' \| relative_url}, File.read!(path)),
          do: asset

    assert length(used) > 10
    for asset <- used, do: assert(File.regular?(asset), "#{asset} is loaded but not there")

    fonts = File.read!("assets/site/css/fonts.css")

    for [_, font] <- Regex.scan(~r{url\(\.\./fonts/([^)]+)\)}, fonts),
        do: assert(File.regular?("assets/site/fonts/" <> font), "#{font} is not there")
  end

  test "every item of the navigation is a page or leaves the site" do
    urls =
      for [_, url] <- Regex.scan(~r/^\s+url: (\S+)$/m, File.read!("_data/nav.yml")), do: url

    assert "/" in urls

    for url <- urls, not String.starts_with?(url, "https://") do
      source =
        cond do
          url == "/" -> "README.md"
          String.ends_with?(url, "/") -> page_of_directory(String.trim_leading(url, "/"))
          true -> String.trim_leading(url, "/") |> String.replace_suffix(".html", ".md")
        end

      assert source && File.regular?(source), "#{url} is not a page"
      refute excluded?(source), "#{url} is a page that _config.yml excludes"
    end
  end

  # A relative link names a file of the repository, as GitHub reads it: a
  # page links to another by its .md file, which the site turns into the
  # page, and to anything else by its path, which the site points at GitHub.
  test "every relative link of a page names a file or directory that is there" do
    pages = ["README.md", "plugin/README.md" | Path.wildcard("docs/**/*.md")]

    for page <- pages,
        [_, target] <- Regex.scan(~r/\]\(([^)\s]+)\)/, File.read!(page)),
        not String.contains?(target, ":"),
        not String.starts_with?(target, "#") do
      path = target |> String.split("#") |> hd() |> then(&Path.join(Path.dirname(page), &1))
      assert File.exists?(path), "#{page} links to #{target}, which is not there"
    end
  end

  test "the site is not in the Hex package" do
    files = Mix.Project.config()[:package][:files]

    for file <- files, site <- @site do
      refute file == site or String.starts_with?(file, site <> "/"),
             "the Hex package holds #{file}, a file of the site"
    end
  end

  defp page_of_directory(dir) do
    Enum.find([dir <> "index.md", dir <> "README.md"], &File.regular?/1)
  end

  defp excluded?(path) do
    for [_, entry] <- Regex.scan(~r/^  - (\S+)$/m, File.read!("_config.yml")),
        reduce: false do
      hit -> hit or path == entry or String.starts_with?(path, entry)
    end
  end
end
