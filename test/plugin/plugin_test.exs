# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Plugin.PluginTest do
  # plugin/: the manifest, and the two scripts that get the server to the
  # user's machine and start it. install-server unpacks nothing that does not
  # match the checksum the plugin pins (or one the user gives); the launcher
  # downloads nothing and hands the server the client's stdin and stdout.
  # The scripts run on a copy of plugin/, with a stand-in server and, for the
  # download, a stand-in curl: nothing here reaches the network. The copy's
  # server.sha256 is the test's own, never the repository's, which pins
  # nothing in a release commit and four tarballs in its pin commit: the
  # install-server tests run with it pinning nothing and pinning four.
  use ExUnit.Case, async: true

  import Bitwise

  @plugin Path.expand("../../plugin", __DIR__)
  @manifest Path.join(@plugin, ".claude-plugin/plugin.json")
  @platforms ~w(linux-arm64 linux-x86_64 macos-arm64 macos-x86_64)
  @pins_comment "# The test's own server.sha256.\n"

  describe "the manifest" do
    test "names the plugin, its version and its pages" do
      manifest = manifest()

      assert manifest["name"] == "noetic-reminisce"
      assert manifest["displayName"] == "reminisce"
      assert manifest["version"] == Mix.Project.config()[:version]
      assert manifest["author"]["name"] == "NoeticEcho"
      assert manifest["license"] == "Apache-2.0"
      assert String.length(manifest["description"]) in 80..400

      for field <-
            ~w(homepage repository documentationUrl supportUrl privacyPolicyUrl termsOfServiceUrl) do
        assert manifest[field] =~
                 ~r{\Ahttps://(open\.noeticecho\.space/reminisce-elixir/|github\.com/NoeticEcho/reminisce-elixir)},
               field
      end

      assert [_ | _] = manifest["keywords"]
      assert %{"object_acted_on" => [_ | _]} = manifest["classification"]
      assert File.regular?(Path.join(@plugin, manifest["icon"]))
    end

    test "asks for the four settings, and keeps the password in secure storage" do
      config = manifest()["userConfig"]
      assert Enum.sort(Map.keys(config)) == ~w(database owner typedb_password typedb_url)

      for {key, entry} <- config do
        assert %{"type" => "string", "title" => _, "description" => _, "required" => true} = entry
        assert Map.keys(entry) -- ~w(type title description required default sensitive) == [], key
      end

      assert config["typedb_password"]["sensitive"] == true
      refute Map.has_key?(config["typedb_password"], "default")
      assert config["database"]["default"] == "reminisce"
      assert config["typedb_url"]["default"] == "http://127.0.0.1:8000"
    end

    test "starts the launcher with the owner and database as arguments, the password in the environment" do
      manifest = manifest()

      assert %{"reminisce" => server} = manifest["mcpServers"]
      assert server["command"] == "${CLAUDE_PLUGIN_ROOT}/bin/reminisce-mcp"
      assert server["args"] == ~w(--owner ${user_config.owner} --database ${user_config.database})

      assert server["env"] == %{
               "TYPEDB_URL" => "${user_config.typedb_url}",
               "TYPEDB_USERNAME" => "admin",
               "TYPEDB_PASSWORD" => "${user_config.typedb_password}"
             }

      # Every setting it names is declared.
      used =
        Regex.scan(~r/\$\{user_config\.([a-z_]+)\}/, Jason.encode!(server),
          capture: :all_but_first
        )

      assert List.flatten(used) -- Map.keys(manifest["userConfig"]) == []
    end

    test "runs nothing at session start but the server" do
      manifest = manifest()

      for key <- ~w(hooks commands agents lspServers monitors),
          do: refute(Map.has_key?(manifest, key))

      refute File.exists?(Path.join(@plugin, "hooks"))
      refute File.exists?(Path.join(@plugin, ".mcp.json"))
    end
  end

  test "plugin/NOTICE and plugin/LICENSE are the repository's" do
    root = Path.expand("..", @plugin)

    assert File.read!(Path.join(@plugin, "NOTICE")) == File.read!(Path.join(root, "NOTICE"))
    assert File.read!(Path.join(@plugin, "LICENSE")) == File.read!(Path.join(root, "LICENSE"))
  end

  test "the plugin does not claim that separate databases keep people apart" do
    text =
      [".claude-plugin/plugin.json", "README.md", "skills/owner-and-scope/SKILL.md"]
      |> Enum.map_join("\n", &File.read!(Path.join(@plugin, &1)))

    refute text =~ ~r/need separate databases/i
    assert text =~ ~r/one password opens every database/i
    assert text =~ ~r/TypeDB (server )?each/i
  end

  test "server.sha256 pins this version's four tarballs or none, in sha256sum's format" do
    version = manifest()["version"]

    lines =
      Path.join(@plugin, "server.sha256")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))

    for line <- lines do
      assert line =~
               ~r/\A[0-9a-f]{64}  reminisce-mcp-#{Regex.escape(version)}-(linux|macos)-(x86_64|arm64)\.tar\.gz\z/
    end

    # The release commit pins none; the commit that pins it once the release
    # is published pins all four.
    platforms = lines |> Enum.map(&(&1 |> String.split("-") |> Enum.take(-2))) |> Enum.sort()

    assert length(lines) in [0, 4] and length(Enum.uniq(platforms)) == length(lines),
           inspect(lines)
  end

  test "the setup skill is the user's to run, and names only the plugin's own scripts" do
    text = File.read!(Path.join(@plugin, "skills/setup/SKILL.md"))
    [_, front, _] = String.split(text, "---\n", parts: 3)
    front = YamlElixir.read_from_string!(front)

    assert front["name"] == "setup"
    assert front["disable-model-invocation"] == true

    scripts = Regex.scan(~r/\$\{CLAUDE_PLUGIN_ROOT\}\/([\w\/.-]+)/, text, capture: :all_but_first)
    assert List.flatten(scripts) |> Enum.sort() == ~w(scripts/install-server typedb/first-run)

    for [script] <- scripts, do: assert(executable?(Path.join(@plugin, script)), script)

    # It never puts the password in a command.
    refute text =~ ~r/TYPEDB_PASSWORD=\S/
  end

  describe "bin/reminisce-mcp" do
    setup :copy

    test "without the server, says how to install it, and starts nothing", %{root: root} do
      {out, status, err} = sh(Path.join(root, "bin/reminisce-mcp"), ["--owner", "user:a"])

      assert status == 1
      assert out == ""
      assert err =~ "the server is not installed in #{root}/server"
      assert err =~ "/noetic-reminisce:setup"
      assert err =~ "sh '#{root}/scripts/install-server'"
    end

    test "hands the server its arguments, stdin, stdout and exit status", %{root: root} do
      {tarball, sha} = tarball(root, exit: 3)
      {_, 0, _} = offline(root, tarball, sha)

      {out, status, _} =
        sh(Path.join(root, "bin/reminisce-mcp"), ["--owner", "user:a b", "--database", ""],
          input: "line one\nline two\n"
        )

      assert status == 3
      assert out == "args: [--owner] [user:a b] [--database] []\nline one\nline two\n"
    end
  end

  for pins <- [:none, :four] do
    describe "scripts/install-server, with server.sha256 pinning #{pins}" do
      @describetag pins: pins
      setup :copy

      test "with no checksum pinned or given, installs no tarball of its own", %{root: root} do
        File.write!(Path.join(root, "server.sha256"), "# None yet.\n")
        {tarball, _sha} = tarball(root)
        {out, status, err} = sh(Path.join(root, "scripts/install-server"), ["--file", tarball])

        assert status == 1
        assert out == ""
        assert err =~ "this plugin pins no checksum for #{name()}.tar.gz"
        assert err =~ "give the tarball's with --sha256. Nothing was installed."
        assert clean?(root)
      end

      test "installs a tarball that matches the pinned checksum, and again", %{root: root} do
        {tarball, sha} = tarball(root)
        pin(root, sha)

        for _ <- 1..2 do
          {out, status, err} = sh(Path.join(root, "scripts/install-server"), ["--file", tarball])
          assert status == 0, err
          assert out == ""
          assert err =~ "installed reminisce-mcp #{version()} for #{platform()} in #{root}/server"
          assert executable?(Path.join(root, "server/bin/reminisce-mcp"))
          assert clean?(root, ["server"])
        end
      end

      test "refuses a tarball that does not match, and keeps the server it has", %{root: root} do
        {good, sha} = tarball(root)
        {_, 0, _} = offline(root, good, sha)
        installed = File.read!(Path.join(root, "server/bin/reminisce-mcp"))

        {bad, _} = tarball(root, exit: 9)
        pin(root, sha)
        {_, status, err} = sh(Path.join(root, "scripts/install-server"), ["--file", bad])

        assert status == 1
        assert err =~ "it is not the release's file. Nothing was installed."
        assert File.read!(Path.join(root, "server/bin/reminisce-mcp")) == installed
        assert clean?(root, ["server"])
      end

      test "refuses a checksum that is not one, and a tarball without the server", %{root: root} do
        {_, status, err} = sh(Path.join(root, "scripts/install-server"), ["--sha256", "ABC"])
        assert status == 1
        assert err =~ "not a SHA-256 in lower-case hex"

        {tarball, sha} = tarball(root, bin: false)
        {_, status, err} = offline(root, tarball, sha)

        assert status == 1
        assert err =~ "does not hold #{name()}/bin/reminisce-mcp. Nothing was installed."
        assert clean?(root)
      end

      test "downloads this version's tarball for this machine from the release, over HTTPS only",
           %{root: root} do
        {tarball, sha} = tarball(root)
        pin(root, sha)
        fake = curl(root, tarball, "0000")

        {_, status, err} =
          sh(Path.join(root, "scripts/install-server"), [],
            path: fake.bin,
            env: [{"CURL_LOG", fake.log}]
          )

        assert status == 0, err
        assert err =~ "downloading #{url()}"
        refute err =~ "pins no checksum"
        # The pinned checksum is the check: the release's own file is not read.
        assert [args] = calls(fake)
        assert List.last(args) == url()
        assert "--proto" in args and "=https" in args
        assert clean?(root, ["server"])
      end

      test "with no checksum pinned, checks against the release's own, and says what that finds",
           %{root: root} do
        File.write!(Path.join(root, "server.sha256"), "# None yet.\n")
        {tarball, sha} = tarball(root)

        fake = curl(root, tarball, "#{sha}  #{name()}.tar.gz")

        {_, status, err} =
          sh(Path.join(root, "scripts/install-server"), [],
            path: fake.bin,
            env: [{"CURL_LOG", fake.log}]
          )

        assert status == 0, err

        assert err =~
                 "this plugin pins no checksum for #{name()}.tar.gz: checking it against #{url()}.sha256"

        assert err =~ "which finds a damaged download, not a release whose files were replaced"
        assert Enum.map(calls(fake), &List.last/1) == [url() <> ".sha256", url()]
        assert clean?(root, ["server"])

        # A release file that does not match is refused.
        File.rm_rf!(Path.join(root, "server"))
        fake = curl(root, tarball, "#{String.duplicate("0", 64)}  #{name()}.tar.gz")

        {_, status, err} =
          sh(Path.join(root, "scripts/install-server"), [],
            path: fake.bin,
            env: [{"CURL_LOG", fake.log}]
          )

        assert status == 1
        assert err =~ "it is not the release's file. Nothing was installed."
        assert clean?(root)
      end
    end
  end

  describe "scripts/install-server and the line it pins" do
    setup :copy

    test "a checksum given with --sha256 that is the pinned one installs", %{root: root} do
      {tarball, sha} = tarball(root)
      pin(root, sha)

      {_, status, err} =
        sh(Path.join(root, "scripts/install-server"), ["--file", tarball, "--sha256", sha])

      assert status == 0, err
      assert executable?(Path.join(root, "server/bin/reminisce-mcp"))
      assert clean?(root, ["server"])
    end

    test "a checksum given with --sha256 that is not the pinned one is refused, naming both",
         %{root: root} do
      {tarball, sha} = tarball(root)
      pinned = String.duplicate("e", 64)
      pin(root, pinned)

      # Neither is taken over the other, whichever the tarball matches.
      for {given, other} <- [{sha, pinned}, {pinned, sha}] do
        if given == pinned, do: pin(root, sha)

        {out, status, err} =
          sh(Path.join(root, "scripts/install-server"), ["--file", tarball, "--sha256", given])

        assert status == 1
        assert out == ""

        assert err =~
                 "--sha256 gives #{given} for #{name()}.tar.gz, but this plugin pins #{other} in #{root}/server.sha256: the two must be the same. Nothing was installed."

        refute err =~ "not a SHA-256"
        assert clean?(root)
      end
    end

    test "takes this machine's line, not another platform's or version's", %{root: root} do
      {tarball, sha} = tarball(root)
      pin(root, sha)

      others =
        for platform <- ~w(linux-arm64 linux-x86_64 macos-arm64 macos-x86_64),
            version <- [version(), "0.0.1"],
            "reminisce-mcp-#{version}-#{platform}" != name(),
            do: "#{String.duplicate("f", 64)}  reminisce-mcp-#{version}-#{platform}.tar.gz\n"

      File.write!(Path.join(root, "server.sha256"), Enum.join(others), [:append])
      {_, status, err} = sh(Path.join(root, "scripts/install-server"), ["--file", tarball])

      assert status == 0, err
      assert clean?(root, ["server"])
    end

    test "refuses a server.sha256 that names this machine's tarball on two lines", %{root: root} do
      {tarball, sha} = tarball(root)

      for second <- [sha, String.duplicate("e", 64)] do
        pin(root, sha)
        File.write!(Path.join(root, "server.sha256"), "#{second}  #{name()}.tar.gz\n", [:append])

        for args <- [["--file", tarball], ["--file", tarball, "--sha256", sha]] do
          {_, status, err} = sh(Path.join(root, "scripts/install-server"), args)

          assert status == 1

          assert err =~
                   "#{root}/server.sha256 names #{name()}.tar.gz on 2 lines, and must on one at most. Nothing was installed."

          assert clean?(root)
        end
      end
    end

    test "refuses a pinned line that is not a SHA-256", %{root: root} do
      {tarball, _} = tarball(root)
      pin(root, String.duplicate("E", 64))
      {_, status, err} = sh(Path.join(root, "scripts/install-server"), ["--file", tarball])

      assert status == 1
      assert err =~ "not a SHA-256 in lower-case hex: #{String.duplicate("E", 64)} (the line for"
      assert clean?(root)
    end
  end

  describe "scripts/install-server, when curl has no CA certificates" do
    setup :copy

    test "says to install ca-certificates", %{root: root} do
      bin = Path.join(Path.dirname(root), "nocerts_" <> hex(4))
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "curl"), "#!/bin/sh\nexit 77\n")
      File.chmod!(Path.join(bin, "curl"), 0o755)

      for pinned? <- [false, true] do
        if pinned?, do: pin(root, String.duplicate("a", 64))
        {_, status, err} = sh(Path.join(root, "scripts/install-server"), [], path: bin)

        assert status == 1
        assert err =~ "curl found no CA certificates"
        assert err =~ "install ca-certificates"
        assert err =~ "Nothing was installed."
        refute err =~ "its reason is above"
        assert clean?(root)
      end
    end
  end

  # A copy of plugin/ to run the scripts in. Its server.sha256 pins nothing,
  # as a release commit's does, or (`pins: :four`) this version's four
  # tarballs, as its pin commit's does: built elsewhere, so not the ones the
  # tests make.
  defp copy(context) do
    tmp = Path.join(System.tmp_dir!(), "t_plugin_" <> hex(5))
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {_, 0} = System.cmd("cp", ["-R", @plugin, tmp])
    root = Path.join(tmp, "plugin")

    lines =
      case Map.get(context, :pins, :none) do
        :none -> []
        :four -> for platform <- @platforms, do: pin_line(platform, :crypto.strong_rand_bytes(32))
      end

    File.write!(Path.join(root, "server.sha256"), [@pins_comment | lines])
    %{root: root}
  end

  # A stand-in server tarball, laid out as the release's: its server prints
  # its arguments, copies stdin to stdout, and exits with `exit`.
  defp tarball(root, opts \\ []) do
    dir = Path.join(Path.dirname(root), "build_" <> hex(4))
    bin = Path.join([dir, name(), "bin"])
    File.mkdir_p!(bin)

    if Keyword.get(opts, :bin, true) do
      server = Path.join(bin, "reminisce-mcp")

      File.write!(server, """
      #!/bin/sh
      printf 'args:'
      for a in "$@"; do printf ' [%s]' "$a"; done
      printf '\\n'
      cat
      exit #{Keyword.get(opts, :exit, 0)}
      """)

      File.chmod!(server, 0o755)
    end

    tarball = Path.join(dir, name() <> ".tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", dir, name()])
    {tarball, :crypto.hash(:sha256, File.read!(tarball)) |> Base.encode16(case: :lower)}
  end

  # server.sha256 pinning this version's four tarballs, `sha` for this
  # machine's.
  defp pin(root, sha) do
    here = platform() |> String.replace(" ", "-")

    lines =
      for platform <- @platforms do
        if platform == here,
          do: "#{sha}  #{name()}.tar.gz\n",
          else: pin_line(platform, :crypto.strong_rand_bytes(32))
      end

    File.write!(Path.join(root, "server.sha256"), [@pins_comment | lines])
  end

  defp pin_line(platform, bytes),
    do:
      "#{Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}  reminisce-mcp-#{version()}-#{platform}.tar.gz\n"

  # install-server --file TARBALL --sha256 SHA, the offline install: on a
  # plugin that pins its tarballs, the pinned one is that same SHA, as it is
  # for the release's own file.
  defp offline(root, tarball, sha) do
    if pinned?(root), do: pin(root, sha)
    sh(Path.join(root, "scripts/install-server"), ["--file", tarball, "--sha256", sha])
  end

  defp pinned?(root),
    do:
      root
      |> Path.join("server.sha256")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.any?(&(not String.starts_with?(&1, "#")))

  # A stand-in curl that logs its arguments, one call to a line, and serves
  # `checksum` for a URL that ends in .sha256 and `tarball` for any other.
  defp curl(root, tarball, checksum) do
    dir = Path.join(Path.dirname(root), "fake_" <> hex(4))
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(dir, "checksum"), checksum <> "\n")

    File.write!(Path.join(bin, "curl"), """
    #!/bin/sh
    printf '%s\\t' "$@" >> "$CURL_LOG"
    printf '\\n' >> "$CURL_LOG"
    for a in "$@"; do url=$a; done
    while [ $# -gt 0 ]; do
      case $1 in -o) out=$2; shift 2 ;; *) shift ;; esac
    done
    case $url in
      *.sha256) cp '#{dir}/checksum' "$out" ;;
      *) cp '#{tarball}' "$out" ;;
    esac
    """)

    File.chmod!(Path.join(bin, "curl"), 0o755)
    %{bin: bin, log: Path.join(dir, "curl.log")}
  end

  defp calls(fake) do
    for line <- fake.log |> File.read!() |> String.split("\n", trim: true),
        do: String.split(line, "\t", trim: true)
  end

  defp url,
    do:
      "https://github.com/NoeticEcho/reminisce-elixir/releases/download/v#{version()}/#{name()}.tar.gz"

  defp sh(script, args, opts \\ []) do
    err = Path.join(System.tmp_dir!(), "t_plugin_err_" <> hex(5))
    on_exit(fn -> File.rm(err) end)

    path =
      case opts[:path] do
        nil -> System.get_env("PATH")
        bin -> bin <> ":" <> System.get_env("PATH")
      end

    {out, status} =
      System.cmd(
        "sh",
        ["-c", ~s(printf '%s' "$T_INPUT" | "$@" 2>"$T_ERR"), "sh", script | args],
        env:
          [{"T_INPUT", Keyword.get(opts, :input, "")}, {"T_ERR", err}, {"PATH", path}] ++
            Keyword.get(opts, :env, [])
      )

    {out, status, File.read!(err)}
  end

  # Nothing left behind in the plugin's directory but `expected`.
  defp clean?(root, expected \\ []) do
    left = File.ls!(root) -- File.ls!(@plugin)
    Enum.sort(left) == Enum.sort(expected)
  end

  defp manifest, do: @manifest |> File.read!() |> Jason.decode!()
  defp version, do: manifest()["version"]
  defp name, do: "reminisce-mcp-#{version()}-#{platform() |> String.replace(" ", "-")}"

  defp platform do
    os = if match?({:unix, :darwin}, :os.type()), do: "macos", else: "linux"
    {machine, 0} = System.cmd("uname", ["-m"])
    arch = if String.trim(machine) in ~w(aarch64 arm64), do: "arm64", else: "x86_64"
    "#{os} #{arch}"
  end

  defp executable?(path),
    do: match?({:ok, %{mode: mode}} when (mode &&& 0o111) != 0, File.stat(path))

  defp hex(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)
end
