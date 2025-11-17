.PHONY: help pdf clean install-deps check-deps pdf-readme pdf-management all

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

pdf: pdf-readme pdf-management ## Generate all PDF documents
	@echo "$(GREEN)✓ All PDFs generated successfully$(NC)"

clean: ## Clean generated PDF files
	@echo "$(YELLOW)Cleaning generated PDFs and images...$(NC)"
	@rm -f $(README_PDF) $(MANAGEMENT_PDF)
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

all: clean pdf ## Clean and generate all PDFs
	@echo "$(GREEN)✓ Complete PDF generation workflow finished successfully$(NC)"

