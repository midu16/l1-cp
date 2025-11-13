# GitHub Workflows

This directory contains GitHub Actions workflows for automating various tasks in the repository.

## Available Workflows

### generate-pdf.yml

Automatically generates PDF documentation from Markdown files.

**Triggers:**
- Push to `main` or `master` branch when README.md or ManagementClusterBP.md changes
- Pull requests that modify documentation files
- Manual trigger via workflow_dispatch

**Generated Artifacts:**
- `README.pdf` - PDF version of the main README
- `ManagementClusterBP-Generated.pdf` - PDF version of the Management Cluster Best Practices document

**Features:**
- Preserves all hyperlinks in the PDF
- Renders Mermaid diagrams
- Generates table of contents
- Numbers sections automatically
- Syntax highlighting for code blocks
- Creates GitHub releases with PDF attachments (on main/master branch)

**Artifacts Retention:** 90 days

### Usage

The workflow runs automatically on push/PR. To trigger manually:

1. Go to the "Actions" tab in GitHub
2. Select "Generate PDF Documentation"
3. Click "Run workflow"
4. Select the branch
5. Click "Run workflow"

### Downloading PDFs

**From Workflow Runs:**
1. Go to Actions → Select the workflow run
2. Scroll down to "Artifacts"
3. Download "documentation-pdfs"

**From Releases:**
- PDFs are automatically attached to releases created on the main/master branch
- Navigate to the "Releases" section to download

