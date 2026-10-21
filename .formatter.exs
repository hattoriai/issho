# `arg` of `Issho.Tool`; an app or a component gets it with `import_deps: [:issho]`.
locals_without_parens = [arg: 2, arg: 3]

[
  import_deps: [:phoenix, :sake],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "e2e/*.exs"]
]
