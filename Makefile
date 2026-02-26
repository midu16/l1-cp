.PHONY: help pdf clean install-deps check-deps pdf-readme pdf-management pdf-all all list-markdown fetch-certificate update-certificate registry-pull-secret update-pull-secret download-oc-tools generate-openshift-install create-agent-iso imageset-config.yml

# Default target
.DEFAULT_GOAL := help

# Colors for output
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
BLUE   := \033[0;34m
NC     := \033[0m # No Color

# Detect if running as root (e.g., in a container)
ifeq ($(shell id -u),0)
    SUDO :=
else
    SUDO := sudo
endif

# Detect Linux distribution
ifeq ($(shell test -f /etc/os-release && grep -q "ID=fedora\|ID=rhel\|ID=\"rhel\"\|ID=centos" /etc/os-release && echo fedora), fedora)
    DISTRO := fedora
    PKG_MANAGER := dnf
else ifeq ($(shell test -f /etc/os-release && grep -q "ID=ubuntu\|ID=debian" /etc/os-release && echo debian), debian)
    DISTRO := debian
    PKG_MANAGER := apt-get
else
    DISTRO := unknown
    PKG_MANAGER := unknown
endif

# Files
README_MD := README.md
README_PDF := README.pdf
MANAGEMENT_MD := ManagementClusterBP.md
MANAGEMENT_PDF := ManagementClusterBP-Generated.pdf

# Find all markdown files (excluding certain directories)
MD_FILES := $(shell find . -name '*.md' \
	-not -path './node_modules/*' \
	-not -path './.git/*' \
	-not -path './abi-templater/workingdir/*' \
	-type f)
PDF_FILES := $(patsubst %.md,%.pdf,$(MD_FILES))

# Tools
PANDOC := pandoc
NPM := npm
PIP := pip3

help: ## Show this help message
	@echo "$(GREEN)Documentation PDF Generator - Makefile Help$(NC)"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""

check-deps: ## Check if required dependencies are installed
	@echo "$(GREEN)Checking dependencies...$(NC)"
	@echo "$(BLUE)Detected OS: $(DISTRO) (package manager: $(PKG_MANAGER))$(NC)"
	@command -v $(PANDOC) >/dev/null 2>&1 || { echo "$(RED)Error: pandoc is not installed. Run 'make install-deps'$(NC)"; exit 1; }
	@command -v xelatex >/dev/null 2>&1 || { echo "$(RED)Error: xelatex is not installed. Run 'make install-deps'$(NC)"; exit 1; }
	@command -v mmdc >/dev/null 2>&1 || { echo "$(YELLOW)Warning: mermaid-cli is not installed. Mermaid diagrams may not render.$(NC)"; }
	@echo "$(GREEN)✓ Core dependencies are installed$(NC)"

install-deps: ## Install required dependencies (auto-detects OS)
	@echo "$(GREEN)Installing dependencies...$(NC)"
	@echo "$(BLUE)Detected OS: $(DISTRO) (package manager: $(PKG_MANAGER))$(NC)"
ifeq ($(DISTRO),fedora)
	@echo "$(BLUE)Installing system packages (Fedora/RHEL)...$(NC)"
	$(SUDO) dnf install -y \
		pandoc \
		texlive-scheme-basic \
		texlive-collection-fontsrecommended \
		texlive-collection-fontsextra \
		texlive-collection-latexextra \
		texlive-xetex \
		librsvg2-tools \
		chromium \
		npm \
		liberation-mono-fonts \
		liberation-sans-fonts \
		liberation-serif-fonts
else ifeq ($(DISTRO),debian)
	@echo "$(BLUE)Installing system packages (Debian/Ubuntu)...$(NC)"
	$(SUDO) apt-get update
	$(SUDO) apt-get install -y \
		pandoc \
		texlive-latex-base \
		texlive-fonts-recommended \
		texlive-fonts-extra \
		texlive-latex-extra \
		texlive-xetex \
		librsvg2-bin \
		chromium-browser \
		npm \
		fonts-liberation
else
	@echo "$(RED)Error: Unsupported distribution. Please install dependencies manually.$(NC)"
	@echo "$(YELLOW)Required packages: pandoc, texlive-xetex, librsvg2-tools/librsvg2-bin, npm$(NC)"
	@exit 1
endif
	@echo "$(BLUE)Installing mermaid-cli...$(NC)"
	$(SUDO) npm install -g @mermaid-js/mermaid-cli
	@echo "$(BLUE)Installing Puppeteer Chrome...$(NC)"
	npx --yes puppeteer browsers install chrome-headless-shell
	@echo "$(BLUE)Installing pandoc-mermaid-filter...$(NC)"
	$(PIP) install --user pandoc-mermaid-filter
	@echo "$(GREEN)✓ All dependencies installed successfully$(NC)"

pdf-readme: check-deps ## Generate PDF from README.md
	@echo "$(GREEN)Generating PDF from $(README_MD)...$(NC)"
	@# Detect Chromium path
	@if [ -f /usr/bin/chromium ]; then \
		CHROMIUM_PATH="/usr/bin/chromium"; \
	elif [ -f /usr/bin/chromium-browser ]; then \
		CHROMIUM_PATH="/usr/bin/chromium-browser"; \
	elif [ -f /usr/bin/google-chrome ]; then \
		CHROMIUM_PATH="/usr/bin/google-chrome"; \
	else \
		CHROMIUM_PATH=""; \
	fi; \
	if [ -n "$$CHROMIUM_PATH" ]; then \
		echo "{\"executablePath\": \"$$CHROMIUM_PATH\", \"args\": [\"--no-sandbox\", \"--disable-setuid-sandbox\"]}" > /tmp/puppeteer-config.json; \
	else \
		echo "{\"args\": [\"--no-sandbox\", \"--disable-setuid-sandbox\"]}" > /tmp/puppeteer-config.json; \
	fi
	@# Create wrapper script for mmdc with puppeteer config
	@printf '#!/bin/bash\nexec mmdc --puppeteerConfigFile /tmp/puppeteer-config.json "$$@"\n' > /tmp/mmdc-wrapper.sh
	@chmod +x /tmp/mmdc-wrapper.sh
	@# Create LaTeX header for proper formatting
	@echo '% Deep list nesting support' > /tmp/latex-header.tex
	@echo '\usepackage{enumitem}' >> /tmp/latex-header.tex
	@echo '\setlistdepth{9}' >> /tmp/latex-header.tex
	@echo '\renewlist{itemize}{itemize}{9}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,1]{label=$$\bullet$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,2]{label=$$\circ$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,3]{label=$$\diamond$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,4]{label=$$\ast$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,5]{label=$$\cdot$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,6]{label=$$\triangleright$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,7]{label=$$\star$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,8]{label=$$\dagger$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,9]{label=$$\ddagger$$}' >> /tmp/latex-header.tex
	@echo '' >> /tmp/latex-header.tex
	@echo '% Better font support for box-drawing characters' >> /tmp/latex-header.tex
	@echo '\usepackage{fontspec}' >> /tmp/latex-header.tex
	@echo '\setmonofont{Liberation Mono}[Scale=0.9]' >> /tmp/latex-header.tex
	@echo '' >> /tmp/latex-header.tex
	@echo '% Prevent code block overflow' >> /tmp/latex-header.tex
	@echo '\usepackage{fvextra}' >> /tmp/latex-header.tex
	@echo '\DefineVerbatimEnvironment{Highlighting}{Verbatim}{breaklines,breakanywhere,commandchars=\\\{\}}' >> /tmp/latex-header.tex
	@echo '' >> /tmp/latex-header.tex
	@echo '% Ensure images fit within margins and center them' >> /tmp/latex-header.tex
	@echo '\usepackage{graphicx}' >> /tmp/latex-header.tex
	@echo '\makeatletter' >> /tmp/latex-header.tex
	@echo '\def\maxwidth{\ifdim\Gin@nat@width>\linewidth\linewidth\else\Gin@nat@width\fi}' >> /tmp/latex-header.tex
	@echo '\def\maxheight{\ifdim\Gin@nat@height>\textheight\textheight\else\Gin@nat@height\fi}' >> /tmp/latex-header.tex
	@echo '\makeatother' >> /tmp/latex-header.tex
	@echo '\setkeys{Gin}{width=\maxwidth,height=\maxheight,keepaspectratio}' >> /tmp/latex-header.tex
	@echo '' >> /tmp/latex-header.tex
	@echo '% Center all images and figures' >> /tmp/latex-header.tex
	@echo '\usepackage{float}' >> /tmp/latex-header.tex
	@echo '\makeatletter' >> /tmp/latex-header.tex
	@echo '\g@addto@macro\@floatboxreset\centering' >> /tmp/latex-header.tex
	@echo '\makeatother' >> /tmp/latex-header.tex
	@echo '\let\origincludegraphics\includegraphics' >> /tmp/latex-header.tex
	@printf '%s\n' '\renewcommand{\includegraphics}[2][]{\centering\origincludegraphics[#1]{#2}}' >> /tmp/latex-header.tex
	MERMAID_BIN=/tmp/mmdc-wrapper.sh $(PANDOC) $(README_MD) \
		-o $(README_PDF) \
		--pdf-engine=xelatex \
		--from=markdown+hard_line_breaks+pipe_tables+backtick_code_blocks \
		--to=pdf \
		--standalone \
		--toc \
		--toc-depth=3 \
		--number-sections \
		--highlight-style=tango \
		--variable=geometry:margin=1in \
		--variable=linkcolor:blue \
		--variable=urlcolor:blue \
		--variable=toccolor:blue \
		--variable=fontsize:11pt \
		--include-in-header=/tmp/latex-header.tex \
		--metadata title="L1-CloudPlatform Documentation" \
		--metadata author="Documentation Team" \
		--metadata date="$$(date +'%Y-%m-%d')" \
		--filter pandoc-mermaid 2>/dev/null || \
	$(PANDOC) $(README_MD) \
		-o $(README_PDF) \
		--pdf-engine=xelatex \
		--from=markdown+hard_line_breaks+pipe_tables+backtick_code_blocks \
		--to=pdf \
		--standalone \
		--toc \
		--toc-depth=3 \
		--number-sections \
		--highlight-style=tango \
		--variable=geometry:margin=1in \
		--variable=linkcolor:blue \
		--variable=urlcolor:blue \
		--variable=toccolor:blue \
		--variable=fontsize:11pt \
		--include-in-header=/tmp/latex-header.tex \
		--metadata title="L1-CloudPlatform Documentation" \
		--metadata author="Documentation Team" \
		--metadata date="$$(date +'%Y-%m-%d')"
	@echo "$(GREEN)✓ Generated $(README_PDF)$(NC)"

pdf-management: check-deps ## Generate PDF from ManagementClusterBP.md
	@if [ -f $(MANAGEMENT_MD) ]; then \
		echo "$(GREEN)Generating PDF from $(MANAGEMENT_MD)...$(NC)"; \
		if [ -f /usr/bin/chromium ]; then \
			CHROMIUM_PATH="/usr/bin/chromium"; \
		elif [ -f /usr/bin/chromium-browser ]; then \
			CHROMIUM_PATH="/usr/bin/chromium-browser"; \
		elif [ -f /usr/bin/google-chrome ]; then \
			CHROMIUM_PATH="/usr/bin/google-chrome"; \
		else \
			CHROMIUM_PATH=""; \
		fi; \
		if [ -n "$$CHROMIUM_PATH" ]; then \
			echo "{\"executablePath\": \"$$CHROMIUM_PATH\", \"args\": [\"--no-sandbox\", \"--disable-setuid-sandbox\"]}" > /tmp/puppeteer-config.json; \
		else \
			echo "{\"args\": [\"--no-sandbox\", \"--disable-setuid-sandbox\"]}" > /tmp/puppeteer-config.json; \
		fi; \
		printf '#!/bin/bash\nexec mmdc --puppeteerConfigFile /tmp/puppeteer-config.json "$$@"\n' > /tmp/mmdc-wrapper.sh; \
		chmod +x /tmp/mmdc-wrapper.sh; \
		echo '% Deep list nesting support' > /tmp/latex-header.tex; \
		echo '\usepackage{enumitem}' >> /tmp/latex-header.tex; \
		echo '\setlistdepth{9}' >> /tmp/latex-header.tex; \
		echo '\renewlist{itemize}{itemize}{9}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,1]{label=$$\bullet$$}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,2]{label=$$\circ$$}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,3]{label=$$\diamond$$}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,4]{label=$$\ast$$}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,5]{label=$$\cdot$$}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,6]{label=$$\triangleright$$}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,7]{label=$$\star$$}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,8]{label=$$\dagger$$}' >> /tmp/latex-header.tex; \
		echo '\setlist[itemize,9]{label=$$\ddagger$$}' >> /tmp/latex-header.tex; \
		echo '' >> /tmp/latex-header.tex; \
		echo '% Better font support for box-drawing characters' >> /tmp/latex-header.tex; \
		echo '\usepackage{fontspec}' >> /tmp/latex-header.tex; \
		echo '\setmonofont{Liberation Mono}[Scale=0.9]' >> /tmp/latex-header.tex; \
		echo '' >> /tmp/latex-header.tex; \
		echo '% Prevent code block overflow' >> /tmp/latex-header.tex; \
		echo '\usepackage{fvextra}' >> /tmp/latex-header.tex; \
		echo '\DefineVerbatimEnvironment{Highlighting}{Verbatim}{breaklines,breakanywhere,commandchars=\\\{\}}' >> /tmp/latex-header.tex; \
		echo '' >> /tmp/latex-header.tex; \
		echo '% Ensure images fit within margins' >> /tmp/latex-header.tex; \
		echo '\usepackage{graphicx}' >> /tmp/latex-header.tex; \
		echo '\makeatletter' >> /tmp/latex-header.tex; \
		echo '\def\maxwidth{\ifdim\Gin@nat@width>\linewidth\linewidth\else\Gin@nat@width\fi}' >> /tmp/latex-header.tex; \
		echo '\def\maxheight{\ifdim\Gin@nat@height>\textheight\textheight\else\Gin@nat@height\fi}' >> /tmp/latex-header.tex; \
		echo '\makeatother' >> /tmp/latex-header.tex; \
		echo '\setkeys{Gin}{width=\maxwidth,height=\maxheight,keepaspectratio}' >> /tmp/latex-header.tex; \
		echo '' >> /tmp/latex-header.tex; \
		echo '% Center all images and figures' >> /tmp/latex-header.tex; \
		echo '\usepackage{float}' >> /tmp/latex-header.tex; \
		echo '\makeatletter' >> /tmp/latex-header.tex; \
		echo '\g@addto@macro\@floatboxreset\centering' >> /tmp/latex-header.tex; \
		echo '\makeatother' >> /tmp/latex-header.tex; \
		echo '\let\origincludegraphics\includegraphics' >> /tmp/latex-header.tex; \
		printf '%s\n' '\renewcommand{\includegraphics}[2][]{\centering\origincludegraphics[#1]{#2}}' >> /tmp/latex-header.tex; \
		MERMAID_BIN=/tmp/mmdc-wrapper.sh $(PANDOC) $(MANAGEMENT_MD) \
			-o $(MANAGEMENT_PDF) \
			--pdf-engine=xelatex \
			--from=markdown+hard_line_breaks+pipe_tables+backtick_code_blocks \
			--to=pdf \
			--standalone \
			--toc \
			--toc-depth=3 \
			--number-sections \
			--highlight-style=tango \
			--variable=geometry:margin=1in \
			--variable=linkcolor:blue \
			--variable=urlcolor:blue \
			--variable=toccolor:blue \
			--variable=fontsize:11pt \
			--include-in-header=/tmp/latex-header.tex \
			--metadata title="Management Cluster Best Practices" \
			--metadata author="Documentation Team" \
			--metadata date="$$(date +'%Y-%m-%d')" \
			--filter pandoc-mermaid 2>/dev/null || \
		$(PANDOC) $(MANAGEMENT_MD) \
			-o $(MANAGEMENT_PDF) \
			--pdf-engine=xelatex \
			--from=markdown+hard_line_breaks+pipe_tables+backtick_code_blocks \
			--to=pdf \
			--standalone \
			--toc \
			--toc-depth=3 \
			--number-sections \
			--highlight-style=tango \
			--variable=geometry:margin=1in \
			--variable=linkcolor:blue \
			--variable=urlcolor:blue \
			--variable=toccolor:blue \
			--variable=fontsize:11pt \
			--include-in-header=/tmp/latex-header.tex \
			--metadata title="Management Cluster Best Practices" \
			--metadata author="Documentation Team" \
			--metadata date="$$(date +'%Y-%m-%d')"; \
		echo "$(GREEN)✓ Generated $(MANAGEMENT_PDF)$(NC)"; \
	else \
		echo "$(YELLOW)Warning: $(MANAGEMENT_MD) not found, skipping...$(NC)"; \
	fi

list-markdown: ## List all markdown files that will be processed
	@echo "$(GREEN)Found markdown files:$(NC)"
	@for md in $(MD_FILES); do \
		echo "  $(BLUE)$$md$(NC) → $${md%.md}.pdf"; \
	done
	@echo ""
	@echo "$(GREEN)Total: $(words $(MD_FILES)) files$(NC)"

pdf-all: check-deps ## Generate PDFs from all markdown files
	@echo "$(GREEN)Generating PDFs from all markdown files...$(NC)"
	@# Setup shared configuration
	@if [ -f /usr/bin/chromium ]; then \
		CHROMIUM_PATH="/usr/bin/chromium"; \
	elif [ -f /usr/bin/chromium-browser ]; then \
		CHROMIUM_PATH="/usr/bin/chromium-browser"; \
	elif [ -f /usr/bin/google-chrome ]; then \
		CHROMIUM_PATH="/usr/bin/google-chrome"; \
	else \
		CHROMIUM_PATH=""; \
	fi; \
	if [ -n "$$CHROMIUM_PATH" ]; then \
		echo "{\"executablePath\": \"$$CHROMIUM_PATH\", \"args\": [\"--no-sandbox\", \"--disable-setuid-sandbox\"]}" > /tmp/puppeteer-config.json; \
	else \
		echo "{\"args\": [\"--no-sandbox\", \"--disable-setuid-sandbox\"]}" > /tmp/puppeteer-config.json; \
	fi
	@printf '#!/bin/bash\nexec mmdc --puppeteerConfigFile /tmp/puppeteer-config.json "$$@"\n' > /tmp/mmdc-wrapper.sh
	@chmod +x /tmp/mmdc-wrapper.sh
	@# Create LaTeX header
	@echo '% Deep list nesting support' > /tmp/latex-header.tex
	@echo '\usepackage{enumitem}' >> /tmp/latex-header.tex
	@echo '\setlistdepth{9}' >> /tmp/latex-header.tex
	@echo '\renewlist{itemize}{itemize}{9}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,1]{label=$$\bullet$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,2]{label=$$\circ$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,3]{label=$$\diamond$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,4]{label=$$\ast$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,5]{label=$$\cdot$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,6]{label=$$\triangleright$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,7]{label=$$\star$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,8]{label=$$\dagger$$}' >> /tmp/latex-header.tex
	@echo '\setlist[itemize,9]{label=$$\ddagger$$}' >> /tmp/latex-header.tex
	@echo '' >> /tmp/latex-header.tex
	@echo '% Better font support for box-drawing characters' >> /tmp/latex-header.tex
	@echo '\usepackage{fontspec}' >> /tmp/latex-header.tex
	@echo '\setmonofont{Liberation Mono}[Scale=0.9]' >> /tmp/latex-header.tex
	@echo '' >> /tmp/latex-header.tex
	@echo '% Prevent code block overflow' >> /tmp/latex-header.tex
	@echo '\usepackage{fvextra}' >> /tmp/latex-header.tex
	@echo '\DefineVerbatimEnvironment{Highlighting}{Verbatim}{breaklines,breakanywhere,commandchars=\\\{\}}' >> /tmp/latex-header.tex
	@echo '' >> /tmp/latex-header.tex
	@echo '% Ensure images fit within margins and center them' >> /tmp/latex-header.tex
	@echo '\usepackage{graphicx}' >> /tmp/latex-header.tex
	@echo '\makeatletter' >> /tmp/latex-header.tex
	@echo '\def\maxwidth{\ifdim\Gin@nat@width>\linewidth\linewidth\else\Gin@nat@width\fi}' >> /tmp/latex-header.tex
	@echo '\def\maxheight{\ifdim\Gin@nat@height>\textheight\textheight\else\Gin@nat@height\fi}' >> /tmp/latex-header.tex
	@echo '\makeatother' >> /tmp/latex-header.tex
	@echo '\setkeys{Gin}{width=\maxwidth,height=\maxheight,keepaspectratio}' >> /tmp/latex-header.tex
	@echo '' >> /tmp/latex-header.tex
	@echo '% Center all images and figures' >> /tmp/latex-header.tex
	@echo '\usepackage{float}' >> /tmp/latex-header.tex
	@echo '\makeatletter' >> /tmp/latex-header.tex
	@echo '\g@addto@macro\@floatboxreset\centering' >> /tmp/latex-header.tex
	@echo '\makeatother' >> /tmp/latex-header.tex
	@echo '\let\origincludegraphics\includegraphics' >> /tmp/latex-header.tex
	@printf '%s\n' '\renewcommand{\includegraphics}[2][]{\centering\origincludegraphics[#1]{#2}}' >> /tmp/latex-header.tex
	@# Process each markdown file
	@for md in $(MD_FILES); do \
		pdf="$${md%.md}.pdf"; \
		title=$$(basename "$$md" .md | sed 's/-/ /g' | sed 's/_/ /g'); \
		echo "$(BLUE)Processing: $$md → $$pdf$(NC)"; \
		MERMAID_BIN=/tmp/mmdc-wrapper.sh $(PANDOC) "$$md" \
			-o "$$pdf" \
			--pdf-engine=xelatex \
			--from=markdown+hard_line_breaks+pipe_tables+backtick_code_blocks \
			--to=pdf \
			--standalone \
			--toc \
			--toc-depth=3 \
			--number-sections \
			--highlight-style=tango \
			--variable=geometry:margin=1in \
			--variable=linkcolor:blue \
			--variable=urlcolor:blue \
			--variable=toccolor:blue \
			--variable=fontsize:11pt \
			--include-in-header=/tmp/latex-header.tex \
			--metadata title="$$title" \
			--metadata author="Documentation Team" \
			--metadata date="$$(date +'%Y-%m-%d')" \
			--filter pandoc-mermaid 2>/dev/null || \
		$(PANDOC) "$$md" \
			-o "$$pdf" \
			--pdf-engine=xelatex \
			--from=markdown+hard_line_breaks+pipe_tables+backtick_code_blocks \
			--to=pdf \
			--standalone \
			--toc \
			--toc-depth=3 \
			--number-sections \
			--highlight-style=tango \
			--variable=geometry:margin=1in \
			--variable=linkcolor:blue \
			--variable=urlcolor:blue \
			--variable=toccolor:blue \
			--variable=fontsize:11pt \
			--include-in-header=/tmp/latex-header.tex \
			--metadata title="$$title" \
			--metadata author="Documentation Team" \
			--metadata date="$$(date +'%Y-%m-%d')"; \
		if [ $$? -eq 0 ]; then \
			echo "$(GREEN)✓ Generated $$pdf$(NC)"; \
		else \
			echo "$(RED)✗ Failed to generate $$pdf$(NC)"; \
		fi; \
	done
	@echo "$(GREEN)✓ All PDFs generated successfully$(NC)"

pdf: pdf-all ## Generate all PDF documents (default: all markdown files)
	@echo "$(GREEN)✓ Complete$(NC)"

clean: ## Clean generated PDF files
	@echo "$(YELLOW)Cleaning generated PDFs and images...$(NC)"
	@rm -f $(PDF_FILES)
	@rm -rf mermaid-images/
	@echo "$(GREEN)✓ Cleaned successfully$(NC)"

validate-links: ## Validate all links in README.md (requires markdown-link-check)
	@echo "$(GREEN)Validating links in $(README_MD)...$(NC)"
	@if command -v markdown-link-check >/dev/null 2>&1; then \
		markdown-link-check $(README_MD); \
	else \
		echo "$(YELLOW)markdown-link-check not installed. Install with: npm install -g markdown-link-check$(NC)"; \
	fi

view-readme-pdf: ## Open the generated README PDF
	@if [ -f $(README_PDF) ]; then \
		xdg-open $(README_PDF) 2>/dev/null || open $(README_PDF) 2>/dev/null || echo "$(YELLOW)Cannot open PDF viewer$(NC)"; \
	else \
		echo "$(RED)$(README_PDF) not found. Run 'make pdf-readme' first.$(NC)"; \
	fi

view-management-pdf: ## Open the generated Management PDF
	@if [ -f $(MANAGEMENT_PDF) ]; then \
		xdg-open $(MANAGEMENT_PDF) 2>/dev/null || open $(MANAGEMENT_PDF) 2>/dev/null || echo "$(YELLOW)Cannot open PDF viewer$(NC)"; \
	else \
		echo "$(RED)$(MANAGEMENT_PDF) not found. Run 'make pdf-management' first.$(NC)"; \
	fi

fetch-certificate: ## Fetch registry certificate and update install-config.yaml
	@echo "$(GREEN)Fetching certificate from registry...$(NC)"
	@if [ -z "$(REGISTRY_URL)" ]; then \
		REGISTRY_URL="infra.5g-deployment.lab:8443"; \
	fi; \
	echo "$(BLUE)Registry URL: $$REGISTRY_URL$(NC)"; \
	REGISTRY_HOST=$$(echo $$REGISTRY_URL | cut -d: -f1); \
	REGISTRY_PORT=$$(echo $$REGISTRY_URL | cut -d: -f2); \
	if [ -z "$$REGISTRY_PORT" ]; then \
		REGISTRY_PORT="443"; \
	fi; \
	echo "$(BLUE)Fetching certificate from $$REGISTRY_HOST:$$REGISTRY_PORT$(NC)"; \
	CERT=$$(openssl s_client -connect $$REGISTRY_HOST:$$REGISTRY_PORT -servername $$REGISTRY_HOST \
		</dev/null 2>/dev/null \
		| sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p'); \
	if [ -z "$$CERT" ]; then \
		echo "$(RED)✗ Failed to fetch certificate from $$REGISTRY_HOST:$$REGISTRY_PORT$(NC)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)✓ Certificate fetched successfully$(NC)"; \
	echo "$$CERT" | head -3; \
	echo "  ..."; \
	echo "$$CERT" | tail -1; \
	if [ -f workingdir/install-config.yaml ]; then \
		echo "$(BLUE)Updating workingdir/install-config.yaml...$(NC)"; \
		sed -i.bak '/additionalTrustBundle:/,/-----END CERTIFICATE-----/d' workingdir/install-config.yaml; \
		echo "additionalTrustBundle: |" >> workingdir/install-config.yaml; \
		echo "$$CERT" | sed 's/^/  /' >> workingdir/install-config.yaml; \
		echo "$(GREEN)✓ Updated workingdir/install-config.yaml$(NC)"; \
		echo "$(YELLOW)Backup saved as: workingdir/install-config.yaml.bak$(NC)"; \
	else \
		echo "$(YELLOW)Warning: workingdir/install-config.yaml not found$(NC)"; \
		echo "$(BLUE)Saving certificate to: workingdir/registry-ca.crt$(NC)"; \
		mkdir -p workingdir; \
		echo "$$CERT" > workingdir/registry-ca.crt; \
		echo "$(GREEN)✓ Certificate saved to workingdir/registry-ca.crt$(NC)"; \
	fi

update-certificate: fetch-certificate ## Alias for fetch-certificate

registry-pull-secret: ## Generate base64 pull secret and update .docker/config.json and install-config.yaml (USERNAME=user PASSWORD=pass)
	@echo "$(GREEN)Generating registry pull secret...$(NC)"
	@if [ -z "$(USERNAME)" ] || [ -z "$(PASSWORD)" ]; then \
		echo "$(RED)✗ Error: USERNAME and PASSWORD are required$(NC)"; \
		echo "$(YELLOW)Usage: make registry-pull-secret USERNAME=myuser PASSWORD=mypass$(NC)"; \
		echo "$(YELLOW)Optional: REGISTRY_URL=infra.5g-deployment.lab:8443$(NC)"; \
		exit 1; \
	fi; \
	if [ -z "$(REGISTRY_URL)" ]; then \
		REGISTRY_URL="infra.5g-deployment.lab:8443"; \
	fi; \
	echo "$(BLUE)Registry URL: $$REGISTRY_URL$(NC)"; \
	echo "$(BLUE)Username: $(USERNAME)$(NC)"; \
	echo "$(BLUE)Encoding credentials...$(NC)"; \
	AUTH_ENCODED=$$(echo -n '$(USERNAME):$(PASSWORD)' | base64 -w 0); \
	if [ -z "$$AUTH_ENCODED" ]; then \
		echo "$(RED)✗ Failed to encode credentials$(NC)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)✓ Credentials encoded successfully$(NC)"; \
	echo "$(BLUE)Encoded auth: $$AUTH_ENCODED$(NC)"; \
	PULL_SECRET="{\"auths\":{\"$$REGISTRY_URL\":{\"auth\":\"$$AUTH_ENCODED\"}}}"; \
	echo "$(BLUE)Generated pull secret:$(NC)"; \
	echo "$$PULL_SECRET" | sed 's/.\{60\}/&\n/g' | sed 's/^/  /'; \
	mkdir -p .docker; \
	if [ -f .docker/config.json ]; then \
		echo "$(BLUE)Updating existing .docker/config.json...$(NC)"; \
		cp .docker/config.json .docker/config.json.bak; \
		if command -v jq >/dev/null 2>&1; then \
			jq --arg registry "$$REGISTRY_URL" --arg auth "$$AUTH_ENCODED" '.auths[$registry] = {"auth": $auth}' .docker/config.json.bak > .docker/config.json || { \
				echo "$(YELLOW)Warning: jq merge failed, trying Python fallback$(NC)"; \
				python3 -c "import json, sys; \
					data = json.load(open('.docker/config.json.bak')); \
					data.setdefault('auths', {})['$$REGISTRY_URL'] = {'auth': '$$AUTH_ENCODED'}; \
					json.dump(data, sys.stdout, indent=2)" > .docker/config.json || { \
					echo "$(RED)✗ Failed to merge config.json, creating new one$(NC)"; \
					echo "$$PULL_SECRET" > .docker/config.json; \
				}; \
			}; \
		else \
			echo "$(BLUE)Merging with Python...$(NC)"; \
			python3 -c "import json, sys; \
				data = json.load(open('.docker/config.json.bak')); \
				data.setdefault('auths', {})['$$REGISTRY_URL'] = {'auth': '$$AUTH_ENCODED'}; \
				json.dump(data, sys.stdout, indent=2)" > .docker/config.json || { \
				echo "$(RED)✗ Failed to merge config.json, creating new one$(NC)"; \
				echo "$$PULL_SECRET" > .docker/config.json; \
			}; \
		fi; \
		echo "$(GREEN)✓ Updated .docker/config.json$(NC)"; \
		echo "$(YELLOW)Backup saved as: .docker/config.json.bak$(NC)"; \
	else \
		echo "$(BLUE)Creating new .docker/config.json...$(NC)"; \
		echo "$$PULL_SECRET" > .docker/config.json; \
		echo "$(GREEN)✓ Created .docker/config.json$(NC)"; \
	fi; \
	if [ -f workingdir/install-config.yaml ]; then \
		echo "$(BLUE)Updating workingdir/install-config.yaml...$(NC)"; \
		cp workingdir/install-config.yaml workingdir/install-config.yaml.bak; \
		sed -i "s|^pullSecret:.*|pullSecret: '$$PULL_SECRET'|" workingdir/install-config.yaml; \
		echo "$(GREEN)✓ Updated workingdir/install-config.yaml$(NC)"; \
		echo "$(YELLOW)Backup saved as: workingdir/install-config.yaml.bak$(NC)"; \
		echo "$(BLUE)Verifying update...$(NC)"; \
		grep "pullSecret:" workingdir/install-config.yaml; \
	else \
		echo "$(YELLOW)Warning: workingdir/install-config.yaml not found$(NC)"; \
		echo "$(BLUE)Saving pull secret to: workingdir/pull-secret.json$(NC)"; \
		mkdir -p workingdir; \
		echo "$$PULL_SECRET" > workingdir/pull-secret.json; \
		echo "$(GREEN)✓ Pull secret saved to workingdir/pull-secret.json$(NC)"; \
	fi

update-pull-secret: registry-pull-secret ## Alias for registry-pull-secret

update-sshkey: ## Update SSH key in install-config.yaml from file (SSHKEY_FILE=/path/to/id_rsa.pub)
	@echo "$(GREEN)Updating SSH key in install-config.yaml...$(NC)"
	@if [ -z "$(SSHKEY_FILE)" ]; then \
		echo "$(RED)✗ Error: SSHKEY_FILE parameter is required$(NC)"; \
		echo "$(YELLOW)Usage: make update-sshkey SSHKEY_FILE=/path/to/id_rsa.pub$(NC)"; \
		echo "$(YELLOW)Example: make update-sshkey SSHKEY_FILE=~/.ssh/id_rsa.pub$(NC)"; \
		exit 1; \
	fi; \
	SSHKEY_PATH=$$(eval echo $(SSHKEY_FILE)); \
	echo "$(BLUE)SSH Key File: $$SSHKEY_PATH$(NC)"; \
	if [ ! -f "$$SSHKEY_PATH" ]; then \
		echo "$(RED)✗ Error: SSH key file not found: $$SSHKEY_PATH$(NC)"; \
		exit 1; \
	fi; \
	echo "$(BLUE)Reading SSH key from file...$(NC)"; \
	SSHKEY=$$(cat "$$SSHKEY_PATH"); \
	if [ -z "$$SSHKEY" ]; then \
		echo "$(RED)✗ Error: SSH key file is empty$(NC)"; \
		exit 1; \
	fi; \
	echo "$(GREEN)✓ SSH key read successfully$(NC)"; \
	KEY_TYPE=$$(echo "$$SSHKEY" | awk '{print $$1}'); \
	KEY_FINGERPRINT=$$(echo "$$SSHKEY" | awk '{print $$2}' | head -c 40); \
	KEY_COMMENT=$$(echo "$$SSHKEY" | awk '{print $$3}'); \
	echo "$(BLUE)Key Type: $$KEY_TYPE$(NC)"; \
	echo "$(BLUE)Fingerprint: $$KEY_FINGERPRINT...$(NC)"; \
	echo "$(BLUE)Comment: $$KEY_COMMENT$(NC)"; \
	if [ -f workingdir/install-config.yaml ]; then \
		echo "$(BLUE)Updating workingdir/install-config.yaml...$(NC)"; \
		cp workingdir/install-config.yaml workingdir/install-config.yaml.bak; \
		sed -i "s|^sshKey:.*|sshKey: '$$SSHKEY'|" workingdir/install-config.yaml; \
		echo "$(GREEN)✓ Updated workingdir/install-config.yaml$(NC)"; \
		echo "$(YELLOW)Backup saved as: workingdir/install-config.yaml.bak$(NC)"; \
		echo "$(BLUE)Verifying update...$(NC)"; \
		grep "sshKey:" workingdir/install-config.yaml | head -c 80; \
		echo "..."; \
	else \
		echo "$(YELLOW)Warning: workingdir/install-config.yaml not found$(NC)"; \
		echo "$(BLUE)Saving SSH key to: workingdir/sshkey.txt$(NC)"; \
		mkdir -p workingdir; \
		echo "$$SSHKEY" > workingdir/sshkey.txt; \
		echo "$(GREEN)✓ SSH key saved to workingdir/sshkey.txt$(NC)"; \
	fi

download-oc-tools: ## Download OpenShift client tools (oc-mirror and openshift-client) - requires VERSION (e.g., VERSION=4.20.4)
	@echo "$(GREEN)Downloading OpenShift client tools...$(NC)"
	@if [ -z "$(VERSION)" ]; then \
		echo "$(RED)✗ Error: VERSION variable is not set.$(NC)"; \
		echo "$(YELLOW)Usage: make download-oc-tools VERSION=4.20.4$(NC)"; \
		echo "$(YELLOW)Or export VERSION before running: export VERSION=4.20.4 && make download-oc-tools$(NC)"; \
		exit 1; \
	fi; \
	mkdir -p ./bin; \
	BASE_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$(VERSION)"; \
	echo "$(BLUE)Version: $(VERSION)$(NC)"; \
	echo "$(BLUE)Base URL: $$BASE_URL$(NC)"; \
	echo "$(BLUE)Downloading oc-mirror.tar.gz...$(NC)"; \
	curl -L -f -o ./oc-mirror.tar.gz "$$BASE_URL/oc-mirror.tar.gz" || { \
		echo "$(RED)✗ Failed to download oc-mirror.tar.gz$(NC)"; \
		exit 1; \
	}; \
	echo "$(GREEN)✓ Downloaded oc-mirror.tar.gz$(NC)"; \
	echo "$(BLUE)Extracting oc-mirror.tar.gz to ./bin/...$(NC)"; \
	tar -xzf ./oc-mirror.tar.gz -C ./bin/ || { \
		echo "$(RED)✗ Failed to extract oc-mirror.tar.gz$(NC)"; \
		exit 1; \
	}; \
	OC_MIRROR_PATH=$$(find ./bin -name "oc-mirror" -type f 2>/dev/null | head -1); \
	if [ -n "$$OC_MIRROR_PATH" ]; then \
		chmod +x "$$OC_MIRROR_PATH"; \
		if [ "$$OC_MIRROR_PATH" != "./bin/oc-mirror" ]; then \
			mv "$$OC_MIRROR_PATH" ./bin/oc-mirror; \
		fi; \
		echo "$(GREEN)✓ Extracted and made executable: ./bin/oc-mirror$(NC)"; \
	else \
		echo "$(YELLOW)Warning: oc-mirror binary not found in archive$(NC)"; \
	fi; \
	echo "$(BLUE)Downloading openshift-client-linux-$(VERSION).tar.gz...$(NC)"; \
	curl -L -f -o ./openshift-client-linux-$(VERSION).tar.gz "$$BASE_URL/openshift-client-linux-$(VERSION).tar.gz" || { \
		echo "$(RED)✗ Failed to download openshift-client-linux-$(VERSION).tar.gz$(NC)"; \
		exit 1; \
	}; \
	echo "$(GREEN)✓ Downloaded openshift-client-linux-$(VERSION).tar.gz$(NC)"; \
	echo "$(BLUE)Extracting openshift-client-linux-$(VERSION).tar.gz to ./bin/...$(NC)"; \
	tar -xzf ./openshift-client-linux-$(VERSION).tar.gz -C ./bin/ || { \
		echo "$(RED)✗ Failed to extract openshift-client-linux-$(VERSION).tar.gz$(NC)"; \
		exit 1; \
	}; \
	OC_PATH=$$(find ./bin -name "oc" -type f 2>/dev/null | head -1); \
	if [ -n "$$OC_PATH" ]; then \
		chmod +x "$$OC_PATH"; \
		if [ "$$OC_PATH" != "./bin/oc" ]; then \
			mv "$$OC_PATH" ./bin/oc; \
		fi; \
		echo "$(GREEN)✓ Extracted and made executable: ./bin/oc$(NC)"; \
	fi; \
	KUBECTL_PATH=$$(find ./bin -name "kubectl" -type f 2>/dev/null | head -1); \
	if [ -n "$$KUBECTL_PATH" ]; then \
		chmod +x "$$KUBECTL_PATH"; \
		if [ "$$KUBECTL_PATH" != "./bin/kubectl" ]; then \
			mv "$$KUBECTL_PATH" ./bin/kubectl; \
		fi; \
		echo "$(GREEN)✓ Extracted and made executable: ./bin/kubectl$(NC)"; \
	fi; \
	echo "$(GREEN)✓ Done. Files extracted to $$(pwd)/bin$(NC)"

generate-openshift-install: ## Generate openshift-install from CatalogSource or release image - requires CATALOGSOURCE_FILE or RELEASE_IMAGE
	@echo "$(GREEN)Generating openshift-install...$(NC)"
	@if [ -z "$(CATALOGSOURCE_FILE)" ] && [ -z "$(RELEASE_IMAGE)" ]; then \
		echo "$(RED)✗ Error: Either CATALOGSOURCE_FILE or RELEASE_IMAGE must be set.$(NC)"; \
		echo "$(YELLOW)Usage options:$(NC)"; \
		echo "$(YELLOW)  1. make generate-openshift-install CATALOGSOURCE_FILE=path/to/catalogsource.yaml$(NC)"; \
		echo "$(YELLOW)  2. make generate-openshift-install RELEASE_IMAGE=registry/release-image:tag$(NC)"; \
		echo "$(YELLOW)  3. make generate-openshift-install CATALOGSOURCE_FILE=path/to/catalogsource.yaml RELEASE_IMAGE=registry/release-image:tag$(NC)"; \
		exit 1; \
	fi; \
	if [ ! -f ./bin/oc ]; then \
		echo "$(RED)✗ Error: ./bin/oc not found. Run 'make download-oc-tools VERSION=<version>' first$(NC)"; \
		exit 1; \
	fi; \
	if [ ! -f .docker/config.json ]; then \
		echo "$(RED)✗ Error: .docker/config.json not found. Docker authentication file is required$(NC)"; \
		echo "$(YELLOW)Create the file or run 'make registry-pull-secret USERNAME=user PASSWORD=pass'$(NC)"; \
		exit 1; \
	fi; \
	RELEASE_IMAGE_URL=""; \
	if [ -n "$(RELEASE_IMAGE)" ]; then \
		RELEASE_IMAGE_URL="$(RELEASE_IMAGE)"; \
		echo "$(BLUE)Using provided RELEASE_IMAGE: $$RELEASE_IMAGE_URL$(NC)"; \
	elif [ -n "$(CATALOGSOURCE_FILE)" ]; then \
		CATALOGSOURCE_PATH=$$(eval echo $(CATALOGSOURCE_FILE)); \
		echo "$(BLUE)CatalogSource file: $$CATALOGSOURCE_PATH$(NC)"; \
		if [ ! -f "$$CATALOGSOURCE_PATH" ]; then \
			echo "$(RED)✗ Error: CatalogSource file not found: $$CATALOGSOURCE_PATH$(NC)"; \
			exit 1; \
		fi; \
		echo "$(BLUE)Extracting image from CatalogSource...$(NC)"; \
		CATALOG_IMAGE=$$(grep -A 1 "^spec:" "$$CATALOGSOURCE_PATH" | grep "image:" | sed 's/.*image:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs); \
		if [ -z "$$CATALOG_IMAGE" ]; then \
			echo "$(RED)✗ Error: Could not extract image from CatalogSource file$(NC)"; \
			echo "$(YELLOW)Expected format: spec.image: <image-url>$(NC)"; \
			exit 1; \
		fi; \
		echo "$(GREEN)✓ Extracted CatalogSource image: $$CATALOG_IMAGE$(NC)"; \
		echo "$(BLUE)Extracting version and registry from CatalogSource image...$(NC)"; \
		VERSION_TAG=$$(echo "$$CATALOG_IMAGE" | sed 's/.*://'); \
		REGISTRY_AND_PATH=$$(echo "$$CATALOG_IMAGE" | sed 's|:[^:]*$$||'); \
		REGISTRY_HOST_PORT=$$(echo "$$REGISTRY_AND_PATH" | cut -d'/' -f1); \
		FULL_PATH=$$(echo "$$REGISTRY_AND_PATH" | cut -d'/' -f2-); \
		REPO_BASE=$$(echo "$$FULL_PATH" | cut -d'/' -f1); \
		VERSION=$$(echo "$$VERSION_TAG" | sed 's/^v//'); \
		if [ -z "$$VERSION" ]; then \
			echo "$(RED)✗ Error: Could not extract version from CatalogSource image tag$(NC)"; \
			echo "$(YELLOW)Please specify RELEASE_IMAGE directly: make generate-openshift-install RELEASE_IMAGE=registry/release-image:tag$(NC)"; \
			exit 1; \
		fi; \
		if [ -z "$$REPO_BASE" ]; then \
			REPO_BASE="hub-demo"; \
		fi; \
		echo "$(BLUE)Detected version: $$VERSION$(NC)"; \
		echo "$(BLUE)Registry: $$REGISTRY_HOST_PORT$(NC)"; \
		echo "$(BLUE)Repository base: $$REPO_BASE$(NC)"; \
		if echo "$$VERSION" | grep -qE "\.[0-9]+-"; then \
			RELEASE_TAG="$$VERSION"; \
			echo "$(BLUE)Using provided full version tag: $$RELEASE_TAG$(NC)"; \
		else \
			echo "$(BLUE)Querying registry for available tags...$(NC)"; \
			REGISTRY_USER_VAL="$(REGISTRY_USER)"; \
			REGISTRY_PASS_VAL="$(REGISTRY_PASS)"; \
			if [ -z "$$REGISTRY_USER_VAL" ] || [ -z "$$REGISTRY_PASS_VAL" ]; then \
				echo "$(YELLOW)Warning: REGISTRY_USER and REGISTRY_PASS not set, trying to extract from .docker/config.json$(NC)"; \
				if [ -f .docker/config.json ]; then \
					AUTH_DATA=$$(python3 -c "import json, sys, base64; \
						data = json.load(open('.docker/config.json')); \
						registry = '$$REGISTRY_HOST_PORT'; \
						if 'auths' in data and registry in data['auths'] and 'auth' in data['auths'][registry]: \
							auth = base64.b64decode(data['auths'][registry]['auth']).decode('utf-8'); \
							print(auth)" 2>/dev/null); \
					if [ -n "$$AUTH_DATA" ]; then \
						REGISTRY_USER_VAL=$$(echo "$$AUTH_DATA" | cut -d':' -f1); \
						REGISTRY_PASS_VAL=$$(echo "$$AUTH_DATA" | cut -d':' -f2); \
					fi; \
				fi; \
			fi; \
			if [ -z "$$REGISTRY_USER_VAL" ] || [ -z "$$REGISTRY_PASS_VAL" ]; then \
				echo "$(RED)✗ Error: Cannot determine registry credentials$(NC)"; \
				echo "$(YELLOW)Please set REGISTRY_USER and REGISTRY_PASS or ensure .docker/config.json contains auth for $$REGISTRY_HOST_PORT$(NC)"; \
				exit 1; \
			fi; \
			REGISTRY_API_URL="https://$$REGISTRY_HOST_PORT/v2/$$REPO_BASE/openshift/release-images/tags/list"; \
			echo "$(BLUE)Querying: $$REGISTRY_API_URL$(NC)"; \
			TAGS_JSON=$$(curl -s -u "$$REGISTRY_USER_VAL:$$REGISTRY_PASS_VAL" -k "$$REGISTRY_API_URL" 2>/dev/null); \
			if [ -z "$$TAGS_JSON" ]; then \
				echo "$(RED)✗ Error: Failed to query registry tags$(NC)"; \
				echo "$(YELLOW)Please check credentials and registry URL$(NC)"; \
				exit 1; \
			fi; \
			if command -v jq >/dev/null 2>&1; then \
				MATCHING_TAG=$$(echo "$$TAGS_JSON" | jq -r --arg version "$$VERSION" '.tags[] | select(startswith($version + ".") and (endswith("-x86_64")))' | sort -V -r | head -1); \
			else \
				MATCHING_TAG=$$(echo "$$TAGS_JSON" | python3 -c "import json, sys; \
					try: \
						data = json.load(sys.stdin); \
						version = '$$VERSION'; \
						tags = data.get('tags', []); \
						if not tags: \
							sys.exit(1); \
						matching = [t for t in tags if t.startswith(version + '.') and t.endswith('-x86_64')]; \
						if matching: \
							matching.sort(reverse=True); \
							print(matching[0]); \
						else: \
							sys.exit(1); \
					except Exception as e: \
						sys.exit(1)" 2>/dev/null); \
			fi; \
			if [ -z "$$MATCHING_TAG" ] || [ "$$MATCHING_TAG" = "null" ]; then \
				echo "$(RED)✗ Error: No matching tag found for version $$VERSION$(NC)"; \
				echo "$(BLUE)Registry response:$(NC)"; \
				if command -v jq >/dev/null 2>&1; then \
					echo "$$TAGS_JSON" | jq '.'; \
				else \
					echo "$$TAGS_JSON"; \
				fi; \
				echo "$(YELLOW)Available tags:$(NC)"; \
				if command -v jq >/dev/null 2>&1; then \
					echo "$$TAGS_JSON" | jq -r '.tags[]' | head -20; \
				else \
					echo "$$TAGS_JSON" | python3 -c "import json, sys; data = json.load(sys.stdin); print('\\n'.join(data.get('tags', [])))" 2>/dev/null | head -20; \
				fi; \
				echo "$(YELLOW)Please specify RELEASE_IMAGE directly or check the version pattern$(NC)"; \
				exit 1; \
			fi; \
			RELEASE_TAG="$$MATCHING_TAG"; \
			echo "$(GREEN)✓ Found matching tag: $$RELEASE_TAG$(NC)"; \
		fi; \
		RELEASE_IMAGE_URL="$$REGISTRY_HOST_PORT/$$REPO_BASE/openshift/release-images:$$RELEASE_TAG"; \
		echo "$(BLUE)Using release image: $$RELEASE_IMAGE_URL$(NC)"; \
	fi; \
	mkdir -p ./bin; \
	mkdir -p ./workingdir/openshift; \
	if [ ! -f ./workingdir/openshift/idms-oc-mirror.yaml ]; then \
		echo "$(YELLOW)Warning: ./workingdir/openshift/idms-oc-mirror.yaml not found, creating empty file$(NC)"; \
		touch ./workingdir/openshift/idms-oc-mirror.yaml; \
	fi; \
	echo "$(BLUE)Extracting openshift-install from release image: $$RELEASE_IMAGE_URL$(NC)"; \
	./bin/oc adm release extract --registry-config=.docker/config.json \
		--idms-file=./workingdir/openshift/idms-oc-mirror.yaml \
		--command=openshift-install \
		--to=./bin \
		"$$RELEASE_IMAGE_URL" || { \
		echo "$(RED)✗ Failed to extract openshift-install from release image$(NC)"; \
		echo "$(YELLOW)Possible reasons:$(NC)"; \
		echo "$(YELLOW)  1. The release image tag format may be different (e.g., 4.18.27-x86_64 instead of 4.18-x86_64)$(NC)"; \
		echo "$(YELLOW)  2. The release image URL path is incorrect$(NC)"; \
		echo "$(YELLOW)  3. Authentication failed - check .docker/config.json$(NC)"; \
		if [ -n "$$REGISTRY_HOST_PORT" ] && [ -n "$$REPO_BASE" ]; then \
			echo "$(YELLOW)To find the correct release image tag, you can:$(NC)"; \
			echo "$(YELLOW)  1. Check your registry for available tags:$(NC)"; \
			echo "$(YELLOW)     skopeo list-tags docker://$$REGISTRY_HOST_PORT/$$REPO_BASE/openshift/release-images$(NC)"; \
			echo "$(YELLOW)  2. Or query with oc:$(NC)"; \
			echo "$(YELLOW)     ./bin/oc adm release info --registry-config=.docker/config.json $$REGISTRY_HOST_PORT/$$REPO_BASE/openshift/release-images:4.18*$(NC)"; \
			echo "$(YELLOW)Solution: Specify RELEASE_IMAGE directly with the full tag:$(NC)"; \
			echo "$(YELLOW)  make generate-openshift-install RELEASE_IMAGE=$$REGISTRY_HOST_PORT/$$REPO_BASE/openshift/release-images:4.18.27-x86_64$(NC)"; \
			echo "$(YELLOW)Note: The command uses --idms-file=./workingdir/openshift/idms-oc-mirror.yaml$(NC)"; \
		else \
			echo "$(YELLOW)Solution: Specify RELEASE_IMAGE directly with the full release image path and tag$(NC)"; \
		fi; \
		exit 1; \
	}; \
	if [ -f ./bin/openshift-install ]; then \
		chmod +x ./bin/openshift-install; \
		echo "$(GREEN)✓ Generated and made executable: ./bin/openshift-install$(NC)"; \
	else \
		echo "$(YELLOW)Warning: openshift-install binary not found after extraction$(NC)"; \
	fi; \
	echo "$(GREEN)✓ Done. openshift-install extracted to $$(pwd)/bin$(NC)"

create-agent-iso: ## Create agent ISO image - copies workingdir to ./hub/ and runs openshift-install agent create image
	@echo "$(GREEN)Creating agent ISO image...$(NC)"
	@if [ ! -f ./bin/openshift-install ]; then \
		echo "$(RED)✗ Error: ./bin/openshift-install not found$(NC)"; \
		echo "$(YELLOW)Run 'make generate-openshift-install' first to generate openshift-install$(NC)"; \
		exit 1; \
	fi; \
	if [ ! -d ./workingdir ]; then \
		echo "$(RED)✗ Error: ./workingdir directory not found$(NC)"; \
		echo "$(YELLOW)Ensure ./workingdir exists with required configuration files$(NC)"; \
		exit 1; \
	fi; \
	echo "$(BLUE)Creating ./hub/ directory...$(NC)"; \
	rm -rf ./hub; \
	mkdir -p ./hub; \
	echo "$(GREEN)✓ Created ./hub/ directory$(NC)"; \
	echo "$(BLUE)Copying content from ./workingdir/ to ./hub/...$(NC)"; \
	cp -r ./workingdir/* ./hub/ 2>/dev/null || { \
		echo "$(YELLOW)Warning: Some files may not have been copied$(NC)"; \
	}; \
	if [ -d ./workingdir/. ]; then \
		cp -r ./workingdir/.[!.]* ./hub/ 2>/dev/null || true; \
	fi; \
	echo "$(GREEN)✓ Copied content to ./hub/$(NC)"; \
	if [ -n "$(OCP_VERSION)" ] && [ -f ./hub/openshift/catalogSource-cs-redhat-operator-index.yaml ]; then \
		OCP_MAJOR_MINOR=$$(echo "$(OCP_VERSION)" | cut -d. -f1,2); \
		echo "$(BLUE)Updating catalogSource image tag to v$$OCP_MAJOR_MINOR (from OCP_VERSION=$(OCP_VERSION))...$(NC)"; \
		sed -i "s|redhat-operators-disconnected:v[0-9]*\.[0-9]*|redhat-operators-disconnected:v$$OCP_MAJOR_MINOR|g" \
			./hub/openshift/catalogSource-cs-redhat-operator-index.yaml; \
		echo "$(GREEN)✓ Updated catalogSource to use redhat-operators-disconnected:v$$OCP_MAJOR_MINOR$(NC)"; \
	else \
		if [ -f ./hub/openshift/catalogSource-cs-redhat-operator-index.yaml ]; then \
			echo "$(YELLOW)⚠ OCP_VERSION not set — catalogSource image tag left unchanged (set OCP_VERSION for correct tag)$(NC)"; \
		fi; \
	fi; \
	echo "$(BLUE)Running openshift-install agent create image...$(NC)"; \
	./bin/openshift-install agent create image --dir ./hub/. --log-level debug || { \
		echo "$(RED)✗ Failed to create agent ISO image$(NC)"; \
		echo "$(YELLOW)Check the logs above for details$(NC)"; \
		exit 1; \
	}; \
	if [ -f ./hub/agent.iso ]; then \
		echo "$(GREEN)✓ Agent ISO created successfully: ./hub/agent.iso$(NC)"; \
	else \
		echo "$(YELLOW)Warning: agent.iso not found in ./hub/ directory$(NC)"; \
		echo "$(YELLOW)Check the output above for any errors$(NC)"; \
	fi; \
	echo "$(GREEN)✓ Done. Agent ISO generation completed$(NC)"

imageset-config.yml: ## Generate templated imageset-config.yml (requires OCP_VERSION, e.g., OCP_VERSION=4.18.27)
	@echo "$(GREEN)Generating imageset-config.yml...$(NC)"
	@if [ -z "$(OCP_VERSION)" ]; then \
		echo "$(RED)✗ Error: OCP_VERSION variable is not set.$(NC)"; \
		echo "$(YELLOW)Usage: make imageset-config.yml OCP_VERSION=4.18.27$(NC)"; \
		echo "$(YELLOW)Or export OCP_VERSION before running: export OCP_VERSION=4.18.27 && make imageset-config.yml$(NC)"; \
		exit 1; \
	fi; \
	if [ ! -f ./imageset-config.sh ]; then \
		echo "$(RED)✗ Error: ./imageset-config.sh not found$(NC)"; \
		exit 1; \
	fi; \
	chmod +x ./imageset-config.sh; \
	OCP_VERSION="$(OCP_VERSION)" SOURCE_INDEX="$${SOURCE_INDEX:-registry.redhat.io/redhat/redhat-operator-index:v$$(echo $(OCP_VERSION) | cut -d. -f1,2)}" IMAGESET_OUTPUT_FILE="imageset-config.yml" ./imageset-config.sh -g || { \
		echo "$(RED)✗ Failed to generate imageset-config.yml$(NC)"; \
		exit 1; \
	}; \
	echo "$(GREEN)✓ Generated imageset-config.yml with OCP_VERSION=$(OCP_VERSION)$(NC)"

all: clean pdf ## Clean and generate all PDFs
	@echo "$(GREEN)✓ Complete PDF generation workflow finished successfully$(NC)"

