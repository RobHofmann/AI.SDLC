# Bicep security rules

The `security-reviewer` agent reads this page when a change touches a `.bicep` or `.bicepparam`
file.

- **A change that opens public network access is a finding**, unless the story asks for public
  access. Examples are `publicNetworkAccess: 'Enabled'`, a network rule set whose `defaultAction` is
  `Allow`, and a firewall rule open to every address. Source:
  [Microsoft cloud security benchmark, NS-2](https://learn.microsoft.com/en-us/security/benchmark/azure/mcsb-network-security#ns-2-secure-cloud-services-with-network-controls).
- **A parameter that holds a secret has `@secure()`**, and no output returns a secret. Source:
  [Linter rule outputs-should-not-contain-secrets](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/linter-rule-outputs-should-not-contain-secrets).
- **A role assignment uses the narrowest role and scope the story needs.** Source:
  [Azure RBAC best practices](https://learn.microsoft.com/en-us/azure/role-based-access-control/best-practices).
- **A role ID comes from the lookup file**, as clause BICEP-02 says in [clauses.md](clauses.md).

## Related

- [Bicep conventions](../SKILL.md) - the Bicep rules this page belongs to.
- [House style](house-style.md) - the Bicep house style, with a source each.
