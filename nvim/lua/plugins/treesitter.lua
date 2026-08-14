return {
  -- Override LazyVim's nvim-treesitter with the community fork
  {
    "nvim-treesitter/nvim-treesitter",
    enabled = false,
  },
  {
    "neovim-treesitter/nvim-treesitter",
    dependencies = {
      "neovim-treesitter/treesitter-parser-registry",
    },
    lazy = false,
    build = ":TSUpdate",
    config = function()
      -- optional - only if you want a custom install dir
      -- require("nvim-treesitter").setup({
      --   install_dir = vim.fn.stdpath("data") .. "/site",
      -- })
    end,
  },
}
