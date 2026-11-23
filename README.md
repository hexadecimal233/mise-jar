# mise-jar

Install executable JARs with mise from GitHub, GitLab, Forgejo/Codeberg, or
Maven.

## Install

From a local checkout:

```sh
mise plugins link jar /path/to/mise-jar
```

From Git:

```sh
mise plugins install jar https://github.com/hexadecimal233/mise-jar
```

## Usage

Install the latest release globally with one command:

```sh
mise use -g jar:owner/my-tool
```

This works when the release has one JAR asset, or one archive with one
executable JAR. For other layouts, add options:

```toml
[tools]
"jar:my-tool" = {
  version = "1.2.3",
  repo = "owner/repo",
  asset = "my-tool-1.2.3.jar",
}
```

## Updates

With a `latest` request, upgrade to the newest release:

```sh
mise upgrade jar:owner/my-tool
```

Pin a version to hold it:

```sh
mise use -g jar:owner/my-tool@1.2.3
```

## Sources

### GitHub

```toml
[tools]
"jar:my-tool" = {
  version = "1.2.3",
  repo = "owner/repo",
  asset = "my-tool-*.jar",
}
```

`asset` accepts `*` and `?`; `{{version}}` is replaced before matching. When
the release has several plausible assets, set `asset` to one exact name.

`owner/repo` also works as the tool name:

```toml
"jar:owner/repo" = "1.2.3"
```

### GitLab

```toml
[tools]
"jar:my-tool" = {
  version = "1.2.3",
  repo = "group/project",
  forge = "gitlab",
  asset = "my-tool-1.2.3.jar",
}
```

Set `api_url` for a self-hosted instance. GitLab subgroups are accepted in
`repo`.

### Forgejo / Codeberg / Gitea

```toml
[tools]
"jar:my-tool" = {
  version = "1.2.3",
  repo = "owner/tool",
  forge = "forgejo",
  api_url = "https://codeberg.org/api/v1",
  asset = "my-tool-1.2.3.jar",
}
```

`forge = "gitea"` is accepted as an alias for `forgejo`.

### Maven

```toml
[tools]
"jar:my-tool" = {
  version = "1.2.3",
  maven = "com.example:my-tool",
  classifier = "all-deps",
  command = "my-tool",
}
```

`maven_repo` changes the repository base. The default is Maven Central.
Classifiers are explicit; the default artifact has no classifier.

### Archive with a JAR inside

```toml
[tools]
"jar:my-tool" = {
  version = "1.2.3",
  repo = "owner/repo",
  asset = "my-tool-1.2.3.zip",
  jar = "lib/my-tool-*.jar",
  strip_components = 1,
}
```

Use `main_class` when the manifest entry point is missing or points at another
entry point:

```toml
main_class = "com.example.Main"
```

## Options

| Option                    | Meaning                                                              |
| ------------------------- | -------------------------------------------------------------------- |
| `repo`                    | `owner/repo` on GitHub, GitLab, or Forgejo                           |
| `maven`                   | Maven `group:artifact`; use instead of `repo`                        |
| `maven_repo`              | Maven repository base; default `https://repo1.maven.org/maven2`      |
| `classifier`              | Maven classifier, such as `all-deps`                                 |
| `forge`                   | `github` (default), `gitlab`, or `forgejo`                           |
| `api_url`                 | API base for a self-hosted forge                                     |
| `asset` / `asset_pattern` | Release asset name or glob                                           |
| `matching`                | Substring filter used when `asset` is unset                          |
| `jar`                     | JAR path or glob inside an archive                                   |
| `main_class`              | Entry point override                                                 |
| `command`                 | Installed command name; default is the tool name                     |
| `java`                    | Java executable                                                      |
| `java_home`               | JDK home                                                             |
| `java_opts`               | Default JVM options                                                  |
| `args`                    | Default CLI arguments; TOML array                                    |
| `strip_components`        | `0` or `1` when extracting an archive                                |
| `checksum`                | `sha256:<hex>` or `sha512:<hex>`                                     |
| `version_prefix`          | Release tag prefix; unset strips `v`, `""` keeps tags                |
| `prerelease`              | Include prereleases                                                  |
| `token`                   | GitLab/Forgejo or GHES token; GitHub API hosts use mise's HTTP token |

## JDK and runtime options

The generated wrapper chooses Java in this order:

1. `JAR_JAVA`
2. `java`
3. `JAR_JAVA_HOME` / `JAVA_HOME` / `java_home`
4. `java` on `PATH`

Pin a JDK with mise:

```toml
[tools]
java = "temurin-21"
"jar:my-tool" = { version = "1.2.3", repo = "owner/repo", asset = "my-tool.jar" }
```

Runtime overrides:

```sh
JAR_JAVA=/path/to/java
JAR_JAVA_HOME=/path/to/jdk
JAR_JAVA_OPTS="-Xmx1g"
```

Default arguments:

```toml
"jar:my-tool" = {
  version = "1.2.3",
  repo = "owner/repo",
  asset = "my-tool.jar",
  java_opts = "-Xmx1g",
  args = ["--quiet", "--format", "json"],
}
```

User arguments follow the configured `args`.

## Behavior

- Versions come from forge releases or `maven-metadata.xml`.
- Downloads use the release digest, a checksum asset, or `checksum` when the
  source provides one.
- A selected archive is scanned for JARs. A JAR is executable when
  `META-INF/MANIFEST.MF` has `Main-Class` and that class exists.
- The wrapper uses `java -jar` for manifest entry points and
  `java -cp <jar> <main_class>` for overrides.
- Release archives that already contain `bin/` use mise's `github:`,
  `gitlab:`, or `forgejo:` backends.

## Limits

- Maven snapshots are unsupported.
- Checksums are verified when the source publishes one; `mise.lock` has no
  artifact URL or checksum for backend plugin tools.
- `mise search` lists registry tools. Add plugin tools through `mise.toml`.
