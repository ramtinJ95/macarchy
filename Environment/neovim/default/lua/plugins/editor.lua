-- Portable personal behavior. Canonical colors remain in colorscheme.lua.
return {
  { "neovim/nvim-lspconfig", opts = { inlay_hints = { enabled = false } } },
  { "folke/noice.nvim", opts = { lsp = { progress = { enabled = false } } } },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      ensure_installed = {
        "lua", "python", "typescript", "vimdoc", "vim", "regex", "terraform",
        "hcl", "java", "c", "cpp", "rust", "sql", "dockerfile", "toml", "json",
        "go", "gitignore", "yaml", "make", "cmake", "markdown", "markdown_inline",
        "bash", "tsx", "css", "html",
      },
    },
  },
  {
    "shortcuts/no-neck-pain.nvim",
    keys = { { "<leader>zz", "<cmd>NoNeckPain<cr>", desc = "Toggle centered editing" } },
    opts = {},
  },
  {
    "vimwiki/vimwiki",
    branch = "dev",
    init = function()
      -- Use Vimwiki's portable default location, never the author's private tree.
      vim.g.vimwiki_list = { { path = vim.fn.expand("~/vimwiki/"), syntax = "markdown", ext = ".md" } }
      vim.g.vimwiki_global_ext = 0
    end,
  },
  {
    "iamcco/markdown-preview.nvim",
    init = function()
      vim.g.mkdp_filetypes = { "markdown", "vimwiki" }
      require("config.markdown-preview").setup()
    end,
    keys = {
      { "<leader>cp", "<cmd>MarkdownPreviewToggle<cr>", ft = { "markdown", "vimwiki" }, desc = "Markdown Preview" },
    },
  },
}
