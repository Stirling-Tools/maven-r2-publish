# maven-r2-publish

GitHub Actions for publishing Maven repositories to Cloudflare R2 (or any S3-compatible bucket) and serving them from https://maven.stirlingpdf.com.

| Action | Use it when |
|---|---|
| [`Stirling-Tools/maven-r2-publish`](#raw-push) | You want an upload that does exactly what it is told: any bucket, any prefix, metadata and overwrites optional. |
| [`Stirling-Tools/maven-r2-publish/release`](#release) | You are releasing to maven.stirlingpdf.com and want the shared Stirling layout: stage, verify, promote, clean up. |
| [`Stirling-Tools/maven-r2-publish/mirror`](#mirror) | You are copying versions already on Maven Central into R2. |

All three are composite actions. They need a Linux runner with `aws`, `python3`, `curl` and bash 4; GitHub's Ubuntu runners have all of them. Pin them to a commit SHA in workflows that require it.

## Credentials

Each action takes the R2 endpoint and an access key pair as inputs. Store them as secrets, either in each repository's `maven` environment or once at organisation level for selected repositories:

| Secret | Value |
|---|---|
| `R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |
| `R2_ACCESS_KEY_ID` | R2 API token access key ID |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret |

## Raw push

Uploads a local Maven repository directory (whatever `./gradlew publish` or `mvn deploy` wrote to a `file:` repository).

```yaml
- uses: Stirling-Tools/maven-r2-publish@v1
  with:
    repo-dir: build/repo
    prefix: experiments/
    endpoint: ${{ secrets.R2_ENDPOINT }}
    access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
    secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
```

| Input | Default | |
|---|---|---|
| `repo-dir` | required | Local Maven repository layout. |
| `bucket` | `stirling-maven` | Bucket name or `s3://` URL. |
| `prefix` | empty | Key prefix; empty is the bucket root. |
| `metadata` | `true` | Rewrite each artifact's `maven-metadata.xml` from the live copy plus the uploaded versions. |
| `overwrite` | `false` | Allow replacing versions already under the prefix. Without it, a version that already exists is refused unless every file already there is byte-identical to the upload, so an interrupted upload can be re-run to completion. |
| `check-url` | empty | Public URL of the prefix. When set, every uploaded file is downloaded back and compared. |

Output `versions`: the uploaded version directories, one per line.

With `metadata: true`, two runs writing the same artifact at once can drop each other's version from `maven-metadata.xml`. Serialise them with a `concurrency` group.

## Release

The opinionated path to maven.stirlingpdf.com. One action, three steps, run from separate jobs so your own verification sits in between:

1. `stage` uploads to `staging/<repository>/<run-id>/` and outputs `staging-url`. It fails before uploading if any version is already released.
2. Your verify jobs resolve the artifacts from `staging-url`.
3. `promote` copies exactly the staged files to the root, rewrites `maven-metadata.xml`, and checks that every file is served unchanged. Released versions are never overwritten; a promote that stopped part-way resumes when re-run, because the files it already uploaded match the staged ones.
4. `cleanup` deletes the staging copy once the release succeeded. Skip it when verify or promote failed, so "Re-run failed jobs" still has the staged set to work from.

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    environment: maven
    outputs:
      staging-url: ${{ steps.stage.outputs.staging-url }}
    steps:
      - uses: actions/checkout@<sha>
      - run: ./gradlew publishAllPublicationsToLocalRepoRepository
      - id: stage
        uses: Stirling-Tools/maven-r2-publish/release@v1
        with:
          step: stage
          repo-dir: build/repo
          endpoint: ${{ secrets.R2_ENDPOINT }}
          access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
          secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}

  verify:
    needs: publish
    runs-on: ubuntu-latest
    steps:
      - run: ./verify.sh "${{ needs.publish.outputs.staging-url }}"

  promote:
    needs: [publish, verify]
    runs-on: ubuntu-latest
    environment: maven
    concurrency:
      group: stirling-maven
      cancel-in-progress: false
    steps:
      - uses: Stirling-Tools/maven-r2-publish/release@v1
        with:
          step: promote
          endpoint: ${{ secrets.R2_ENDPOINT }}
          access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
          secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}

  cleanup:
    needs: [publish, verify, promote]
    if: ${{ always() && needs.publish.result == 'success' && needs.verify.result != 'failure' && needs.promote.result != 'failure' }}
    runs-on: ubuntu-latest
    environment: maven
    steps:
      - uses: Stirling-Tools/maven-r2-publish/release@v1
        with:
          step: cleanup
          endpoint: ${{ secrets.R2_ENDPOINT }}
          access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
          secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
```

The promote job must use the `stirling-maven` concurrency group, so releases from different repositories never rewrite the same metadata at once. The staging path comes from the repository name and run ID, so re-running failed jobs in the same run finds the same staging copy.

Staging copies from runs that failed and were never re-run stay in the bucket. Add an R2 lifecycle rule that deletes objects under `staging/` after a few days.

`maven-metadata.xml` orders versions the way Maven does: `1.2.0-rc1` < `1.2.0` < `1.2.0.1`, so a later pre-release never becomes `latest` or `release`.

| Input | Default | |
|---|---|---|
| `step` | required | `stage`, `promote` or `cleanup`. |
| `repo-dir` | | Required for `stage`. |
| `bucket` | `stirling-maven` | |
| `public-url` | `https://maven.stirlingpdf.com/` | |

Outputs: `staging-url` and `staging-prefix`, set on every step.

## Mirror

Copies versions from a Maven repository that serves directory listings (Maven Central by default) into the bucket. Every file is checked against the source's `.sha1`, uploaded, then downloaded back from the public URL and compared.

```yaml
jobs:
  mirror:
    runs-on: ubuntu-latest
    environment: maven
    concurrency:
      group: stirling-maven
      cancel-in-progress: false
    steps:
      - uses: Stirling-Tools/maven-r2-publish/mirror@v1
        with:
          group: com.stirling
          artifact: jpdfium
          endpoint: ${{ secrets.R2_ENDPOINT }}
          access-key-id: ${{ secrets.R2_ACCESS_KEY_ID }}
          secret-access-key: ${{ secrets.R2_SECRET_ACCESS_KEY }}
```

| Input | Default | |
|---|---|---|
| `group`, `artifact` | required | The artifact whose versions are listed, e.g. `com.stirling` / `jpdfium`. |
| `modules` | the artifact | Space-separated artifact name prefixes to copy; `jpdfium` also copies `jpdfium-bom`, `jpdfium-natives-*` and so on. |
| `versions` | `all` | `all`, or a list such as `1.2.0,1.3.0`. |
| `latest` | `5` | With `all`, how many of the newest versions. |
| `source` | Maven Central | |
| `destination` | empty | Bucket prefix; empty is the live root. |
| `dry-run` | `false` | Only list the plan. |

Versions already at the destination are skipped, `latest` counts in Maven's version order, and a module with no listing for a version (HTTP 404) is skipped while any other listing failure stops the run before anything is uploaded. Outputs: `versions` (JSON array of versions copied, or planned on a dry run) and `url`.

## Testing

`tests/e2e.sh` runs the scripts against any S3 server that serves the bucket anonymously; CI runs it and every action against [moto](https://github.com/getmoto/moto):

```bash
ENDPOINT=http://localhost:9000 BUCKET=e2e PUBLIC_URL=http://localhost:9000/e2e/ bash tests/e2e.sh
```
