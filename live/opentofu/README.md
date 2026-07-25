# opentofu

This directory contains the OpenTofu manifest for all of my experimental environment.

## Modules

The OpenTofu modules used here no longer live in this repository. They were moved to
[`kholisrag/iac-modules`](https://github.com/kholisrag/iac-modules), where each module is
versioned and released independently by release-please.

Every `terragrunt.hcl` references a released module by its immutable per-module tag:

```hcl
terraform {
  source = "git::https://github.com/kholisrag/iac-modules.git?ref=aws-vpc/v0.1.0"
}
```

The tag's root commit *is* the module, so no `//<subdir>` selector is needed. Floating
`<module>/v0` and `<module>/v0.1` tags also exist, but stacks here pin the exact patch
version so a module release never changes a plan by surprise.

### Bumping a module

1. Land the change in `kholisrag/iac-modules` with a Conventional Commit PR title
   (`feat:` → minor, `fix:` → patch while pre-1.0).
2. Merge the release-please PR it opens. That publishes `<module>/vX.Y.Z`.
3. Update the `ref=` here and run `terragrunt plan` before applying — verify the plan shows
   no unexpected resource recreation (module-side resource address changes are a consumer
   migration and need `moved` / `import` / `state mv` at the leaf).

`modules/argocd/` is unaffected — those are Kustomize bases, not OpenTofu modules, and stay
in this repository.
