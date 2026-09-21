targetScope = 'subscription'

// Grants the deployment identity Contributor on the subscription this module is scoped to.
//
// Split out of infra/bootstrap/main.bicep because a role assignment is created at the scope
// it applies to. The bootstrap root is subscription-scoped, so reaching another subscription
// means a module with `scope: subscription(<id>)` - the same pattern infra/main.bicep uses to
// place hubs and spokes in other subscriptions.

@description('Required. Object ID of the service principal that receives the role assignment. This is the principal ID of the user-assigned managed identity, not its client ID.')
@minLength(36)
@maxLength(36)
param principalId string

@description('Required. Resource ID of the managed identity receiving the assignment. Used only to compose a deterministic assignment name, because the name must be calculable before the deployment starts.')
@minLength(1)
param identityResourceId string

@description('Required. GUID of the built-in role definition to assign. The full resource ID is composed inside this module so that it resolves against the subscription being assigned on, not the one the bootstrap root was deployed to.')
@minLength(36)
@maxLength(36)
param roleDefinitionGuid string

@description('Optional. Description recorded on the role assignment, so its purpose is visible in the portal.')
@maxLength(1024)
param assignmentDescription string = 'Lets GitHub Actions deploy infra/main.bicep into this subscription.'

// Resolved here rather than passed in. subscriptionResourceId() binds to this module's target
// subscription, so a cross-subscription assignment references a role definition ID in the
// subscription it is actually created in.
var roleDefinitionResourceId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  roleDefinitionGuid
)

// Raw resource exception.
//
// AVM catalog checked 2026-09-21. The only published role assignment module,
// br/public:avm/ptn/authorization/role-assignment:0.2.4, declares targetScope =
// 'managementGroup'. It cannot be invoked at subscription scope, and using it would demand
// management group write permission that a subscription-scope assignment does not require.
// There is no avm/res/authorization/role-assignment in the public registry.
//
// Re-evaluate on the next AVM upgrade: replace this if a subscription-scope role assignment
// module is published. The same exception is documented in infra/bootstrap/main.bicep.
//
// The name is a deterministic guid of scope, identity and role definition, so redeploying is
// a no-op rather than a duplicate assignment.
resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, identityResourceId, roleDefinitionResourceId)
  properties: {
    roleDefinitionId: roleDefinitionResourceId
    principalId: principalId
    // Required. Without it the assignment fails while a freshly created identity's service
    // principal is still replicating, because Azure falls back to a directory lookup to infer
    // the type.
    principalType: 'ServicePrincipal'
    description: assignmentDescription
  }
}

@description('Resource ID of the role assignment.')
output resourceId string = assignment.id

@description('Subscription the role was assigned on.')
output subscriptionId string = subscription().subscriptionId
