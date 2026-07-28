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
        uses: fasuizu-br/brainiall-pdf-to-markdown-action@v1.0.0
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

## Local tests

The isolated test suite replaces curl with a local mock. It makes no network request and uses no real secret:

```bash
./scripts/test.sh
```

It covers successful Markdown and JSON conversion, missing credentials, malformed page ranges, invalid PDF content, symlink rejection, HTTP failure, output preservation, temporary-file cleanup, and log redaction.

## License

[MIT](LICENSE) © 2026 Brainiall
