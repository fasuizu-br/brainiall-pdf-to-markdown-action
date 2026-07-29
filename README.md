# Brainiall PDF to Markdown Action

Convert a PDF in your GitHub Actions workflow into clean Markdown for documentation, RAG, search, and LLM pipelines. The action sends only the selected PDF to the hosted [Brainiall PDF to Markdown API](https://www.brainiall.com/en/apis/pdf-to-markdown) and writes the response inside the job workspace.

## Quick start

1. Create a Brainiall API key at [app.brainiall.com](https://app.brainiall.com/?utm_source=github&utm_medium=marketplace&utm_campaign=pdf_to_markdown_action).
2. Save it as a repository or organization Actions secret named `BRAINIALL_API_KEY`.
3. Add the action after checkout:

```yaml
name: Convert PDF

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  convert:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - name: Prepare output directory
        run: mkdir -p build

      - name: Convert PDF to Markdown
        id: pdf
        uses: fasuizu-br/brainiall-pdf-to-markdown-action@v1.1.0
        with:
          pdf_path: docs/manual.pdf
          api_key: ${{ secrets.BRAINIALL_API_KEY }}
          output_path: build/manual.md
          page_range: 1-20
          output_format: markdown

      - name: Upload Markdown
        uses: actions/upload-artifact@v4
        with:
          name: manual-markdown
          path: ${{ steps.pdf.outputs.output_path }}
```

The parent directory of `output_path` must already exist. If necessary, create it in an earlier workflow step. When `output_path` is omitted, the action writes beside the input file with a `.md` extension (`.json` when `output_format: json`).

## Inputs

| Input | Required | Default | Description |
|---|---:|---|---|
| `pdf_path` | yes | — | PDF file inside `GITHUB_WORKSPACE`. Relative paths are resolved from the workspace root. |
| `api_key` | yes | — | Brainiall API key. Always pass it through `${{ secrets.BRAINIALL_API_KEY }}`. |
| `output_path` | no | input name + `.md` | Destination inside `GITHUB_WORKSPACE`; its parent directory must exist. |
| `page_range` | no | all pages | One positive page or an inclusive range such as `1-10`. |
| `output_format` | no | `markdown` | `markdown` for raw Markdown or `json` for Markdown plus structured page data. |

## Outputs

| Output | Description |
|---|---|
| `output_path` | Absolute path of the generated Markdown or JSON file. |

## Security and failure behavior

- `api_key` is mandatory and is never printed by the action. The key is supplied to curl through a private temporary header file, not a command-line argument, and the file is removed after the request.
- The fixed HTTPS endpoint receives both `Authorization: Bearer` and `Ocp-Apim-Subscription-Key` headers.
- Input and output paths must resolve inside `GITHUB_WORKSPACE`; symbolic-link inputs and outputs are rejected.
- The input must be a readable, non-empty regular file with a PDF signature.
- Invalid inputs, transport failures, non-2xx responses, and empty responses fail the step. An existing output is replaced only after a successful response.
- The action does not retry the POST request, avoiding duplicate processing or metered usage after an ambiguous failure.

The conversion uses an external, metered Brainiall service. Review current pricing and data-handling terms before processing sensitive documents. Do not put an API key directly in workflow YAML, repository variables, artifacts, or logs.

## Long contracts in bounded ranges

The example [`convert-long-contract-in-ranges.yml`](examples/convert-long-contract-in-ranges.yml)
converts four explicit 100-page ranges one at a time and uploads each Markdown
range as a separate artifact. It deliberately does not concatenate the files or
claim that headings, tables, clauses, or page boundaries remain continuous
between ranges; those checks belong to the caller's document pipeline.

This pattern responds to an observed operational problem in a public
[LiteParse issue about 379–1,668-page legal and construction contracts](https://github.com/run-llama/liteparse/issues/315),
where 100-page windows stalled or drifted. That report is evidence of the job to
be done, not a benchmark against Brainiall. Run a non-sensitive, authorized
fixture first, review every range, and edit the matrix to the actual page count.
Each range is a separate hosted, metered request; `max-parallel: 1` limits
concurrency but does not make the calls free.

## Local tests

The isolated test suite replaces curl with a local mock. It makes no network request and uses no real secret:

```bash
./scripts/test.sh
```

It covers successful Markdown and JSON conversion, missing credentials, malformed page ranges, invalid PDF content, symlink rejection, HTTP failure, output preservation, temporary-file cleanup, and log redaction.

## n8n workflow

[`examples/n8n-brainiall-pdf-to-markdown.json`](examples/n8n-brainiall-pdf-to-markdown.json) is an importable workflow that exposes a password-protected PDF upload form, sends the PDF to Brainiall as multipart form data, and returns the result in the binary property `markdown`.

Use **n8n 2.27.0 or newer**. That release includes n8n's fix for preserving filenames in multipart binary uploads.

1. Download the [raw workflow JSON](https://raw.githubusercontent.com/fasuizu-br/brainiall-pdf-to-markdown-action/main/examples/n8n-brainiall-pdf-to-markdown.json).
2. In n8n, choose **Import from File** and select the JSON.
3. Open **Upload PDF** and select a **Basic Auth** credential. This prevents anonymous use of the metered endpoint.
4. Open **Convert PDF to Markdown** and select a **Header Auth** credential with:
   - header name: `Authorization`
   - header value: `Bearer YOUR_BRAINIALL_API_KEY`, replacing the placeholder only inside the credential
5. Run the trigger's test form with one PDF. A successful execution exposes the generated `.md` content in the binary property `markdown`.
6. Activate the workflow only after both credentials are configured. Use the production form URL for subsequent uploads.

No credential, credential ID, or API key is embedded in the JSON. The upload form intentionally fails closed until its Basic Auth credential is selected, and the API call returns `401` without a valid Brainiall key.

Validate the checked-in template with Node.js:

```bash
node scripts/validate-n8n-workflow.mjs
```

## License

[MIT](LICENSE) © 2026 Brainiall
