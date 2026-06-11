output "cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "cluster_oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "location" {
  value = azurerm_resource_group.main.location
}

output "acr_login_server" {
  description = "ACR login server URL — use as image registry prefix"
  value       = azurerm_container_registry.main.login_server
}

output "acr_name" {
  value = azurerm_container_registry.main.name
}

output "github_actions_client_id" {
  description = "Entra app client ID — set as AZURE_CLIENT_ID secret in GitHub"
  value       = azuread_application.github_actions.client_id
}

output "kyverno_client_id" {
  description = "Entra app client ID for Kyverno workload identity"
  value       = azuread_application.kyverno.client_id
}

output "tenant_id" {
  description = "Entra tenant ID — set as AZURE_TENANT_ID secret in GitHub"
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Azure subscription ID — set as AZURE_SUBSCRIPTION_ID secret in GitHub"
  value       = data.azurerm_client_config.current.subscription_id
}

output "kubeconfig_command" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}
