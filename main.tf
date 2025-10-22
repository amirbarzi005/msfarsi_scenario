###############################################################
# 🌍 Provider Configuration
###############################################################
provider "azurerm" {
  features {}
  subscription_id = "18a54fef-d36d-4d1c-b7b4-c468a773149b"
}

data "http" "my_ip" {
  url = "https://api.ipify.org"
}

data "azurerm_client_config" "current" {}

###############################################################
# 📦 Local Variables
###############################################################
locals {
  resource_group_name = "rg-abarzi-sch"
  location            = "Sweden Central"
  vnet_name           = "vnet-shared-swc"
  address_space       = ["10.50.0.0/16"]

  subnets = {
    sub-apps = "10.50.1.0/24"
    sub-mgmt = "10.50.0.0/24"
  }

  tags = {
    owner = "amir"
  }

  my_ip_cidr = "${data.http.my_ip.response_body}/32"
}

###############################################################
# 🕸️ Networking: VNet & Subnets
###############################################################
resource "azurerm_virtual_network" "vnet" {
  name                = local.vnet_name
  location            = local.location
  resource_group_name = local.resource_group_name
  address_space       = local.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "subnets" {
  for_each             = local.subnets
  name                 = each.key
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [each.value]
}

###############################################################
# 🔒 Network Security Groups
###############################################################
resource "azurerm_network_security_group" "nsgs" {
  for_each            = local.subnets
  name                = "nsg-${each.key}"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "rdp_from_my_ip" {
  name                        = "Allow-RDP-From-My-IP"
  priority                    = 310
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "${data.http.my_ip.response_body}/32"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.nsgs["sub-mgmt"].name
}

resource "azurerm_network_security_rule" "rdp_internal_subapps" {
  name                        = "Allow-RDP-From-sub-mgmt"
  priority                    = 310
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "10.50.0.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.nsgs["sub-apps"].name
}

resource "azurerm_network_security_rule" "http_subapps" {
  name                        = "Allow-HTTP"
  priority                    = 320
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "10.50.0.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.nsgs["sub-apps"].name
}

resource "azurerm_network_security_rule" "https_subapps" {
  name                        = "Allow-HTTPS"
  priority                    = 330
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "10.50.0.0/24"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.nsgs["sub-apps"].name
}

# ✅ Association
resource "azurerm_subnet_network_security_group_association" "nsg_assoc" {
  for_each                  = local.subnets
  subnet_id                 = azurerm_subnet.subnets[each.key].id
  network_security_group_id = azurerm_network_security_group.nsgs[each.key].id
}

###############################################################
# 🔐 Key Vault for VM password
###############################################################
resource "azurerm_key_vault" "main" {
  name                       = "kv-admin4-swc"
  location                   = local.location
  resource_group_name        = local.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = local.tags
}

resource "azurerm_key_vault_access_policy" "self" {
  key_vault_id       = azurerm_key_vault.main.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = data.azurerm_client_config.current.object_id
  secret_permissions = ["Get", "List"]
}

data "azurerm_key_vault_secret" "vm_admin_pwd" {
  name         = "amir"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_key_vault_access_policy.self]
}

###############################################################
# 🌐 Network Interfaces & IPs
###############################################################


resource "azurerm_public_ip" "vm_pip_mgmt" {
  name                = "pip-vm-mgmt-swc"
  location            = local.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "vm_nics" {
  for_each = {
    vm-web1-demo = "sub-apps"
    vm-web2-demo = "sub-apps"
    vm-mgmt-swc  = "sub-mgmt"
  }

  name                = "nic-${each.key}"
  location            = local.location
  resource_group_name = local.resource_group_name

  ip_configuration {
    name                          = "ipconfig-${each.key}"
    subnet_id                     = azurerm_subnet.subnets[each.value].id
    private_ip_address_allocation = "Dynamic"

    public_ip_address_id = each.key == "vm-mgmt-swc" ? azurerm_public_ip.vm_pip_mgmt.id : null
  }

  tags = local.tags
}

###############################################################
# 💻 Windows Virtual Machines
###############################################################
resource "azurerm_windows_virtual_machine" "vms" {
  for_each = {
    vm-web1-demo = "sub-apps"
    vm-web2-demo = "sub-apps"
    vm-mgmt-swc  = "sub-mgmt"
  }

  name                = each.key
  location            = local.location
  resource_group_name = local.resource_group_name
  network_interface_ids = [
    azurerm_network_interface.vm_nics[each.key].id
  ]
  size           = "Standard_D2as_v5"
  zone           = "1"
  admin_username = "amir"
  admin_password = data.azurerm_key_vault_secret.vm_admin_pwd.value

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  boot_diagnostics {}
  tags = local.tags
}


###############################################################
# 🌐 Public Load Balancer for Web Tier (HTTPS Only)
###############################################################

# Public IP for Load Balancer
resource "azurerm_public_ip" "lb_pip" {
  name                = "pip-LB-demo-sc"
  location            = local.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# Load Balancer Resource
resource "azurerm_lb" "lb_demo_sc" {
  name                = "LB-demo-sc"
  location            = local.location
  resource_group_name = local.resource_group_name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicFrontEnd"
    public_ip_address_id = azurerm_public_ip.lb_pip.id
  }

  tags = local.tags
}

# Backend Address Pool
resource "azurerm_lb_backend_address_pool" "lb_backend" {
  loadbalancer_id = azurerm_lb.lb_demo_sc.id
  name            = "BackendPool"
}

# Associate VMs' NICs to LB backend pool
resource "azurerm_network_interface_backend_address_pool_association" "nic_lb_assoc" {
  for_each = {
    vm-web1-demo = azurerm_network_interface.vm_nics["vm-web1-demo"].id
    vm-web2-demo = azurerm_network_interface.vm_nics["vm-web2-demo"].id
  }

  network_interface_id    = each.value
  ip_configuration_name   = "ipconfig-${each.key}"
  backend_address_pool_id = azurerm_lb_backend_address_pool.lb_backend.id
}

# Health Probe for HTTP (port 80)
resource "azurerm_lb_probe" "http_probe" {
  name            = "http-probe"
  loadbalancer_id = azurerm_lb.lb_demo_sc.id
  port            = 80
  protocol        = "Tcp"
}

# Health Probe for HTTPS (port 443)
resource "azurerm_lb_probe" "https_probe" {
  name            = "https-probe"
  loadbalancer_id = azurerm_lb.lb_demo_sc.id
  port            = 443
  protocol        = "Tcp"
}

# Load Balancing Rule (HTTPS Only)
resource "azurerm_lb_rule" "https_rule" {
  name                           = "https-rule"
  loadbalancer_id                = azurerm_lb.lb_demo_sc.id
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "PublicFrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.lb_backend.id]
  probe_id                       = azurerm_lb_probe.https_probe.id
}
