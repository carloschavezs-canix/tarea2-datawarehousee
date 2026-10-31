terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}
provider "azurerm" {
  features {}
  subscription_id = "12e0f74e-5ba2-4736-88fe-a2b5e7e128d2"
}
locals {
  erp_seed_version = "1"
  raw_files = setunion(
    fileset(path.module, "datos_csv/*.csv"),
    fileset(path.module, "datos_xls/*.xlsx"),
  )
  erp_sql_scripts = [
    "01_crear_esquema.sql",
    "02_catalogos.sql",
    "03_datos_2024.sql",
    "04_datos_2025.sql",
  ]
}
resource "azurerm_resource_group" "rg" {
  name     = "gr-ucb-transporte"
  location = "brazilsouth"
}
resource "azurerm_storage_account" "storage" {
  name                            = "saucbtransporteale2026"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  allow_nested_items_to_be_public = true
  min_tls_version                 = "TLS1_2"
}
resource "azurerm_storage_container" "raw" {
  name                  = "raw"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "blob"
}
resource "azurerm_storage_blob" "raw_files" {
  for_each               = local.raw_files
  name                   = each.value
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = azurerm_storage_container.raw.name
  type                   = "Block"
  source                 = "${path.module}/${each.value}"
  content_md5            = filemd5("${path.module}/${each.value}")
  content_type           = length(regexall("\\.csv$", lower(each.value))) > 0 ? "text/csv" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
}
resource "azurerm_mssql_server" "sql_server" {
  name                         = "sql-ucb-server-transporte-ale2026"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "alejandro"
  administrator_login_password = "PasswordComplejo1234!"
  minimum_tls_version          = "1.2"
}
resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAllWindowsAzureIps"
  server_id        = azurerm_mssql_server.sql_server.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}
resource "azurerm_mssql_firewall_rule" "allow_azure_services_explicit" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.sql_server.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
resource "azurerm_mssql_database" "db" {
  for_each                    = toset(["erp_transporte_db", "dw_transporte"])
  name                        = each.value
  server_id                   = azurerm_mssql_server.sql_server.id
  collation                   = "SQL_Latin1_General_CP1_CI_AS"
  sku_name                    = "GP_S_Gen5_1"
  max_size_gb                 = 32
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = 60
}
resource "terraform_data" "erp_schema" {
  triggers_replace = [
    azurerm_mssql_database.db["erp_transporte_db"].id,
    local.erp_seed_version,
  ]
  depends_on = [azurerm_mssql_firewall_rule.allow_azure_services]
  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-Command"]
    environment = {
      SQL_SERVER      = azurerm_mssql_server.sql_server.fully_qualified_domain_name
      SQL_DATABASE    = azurerm_mssql_database.db["erp_transporte_db"].name
      SQL_USER        = azurerm_mssql_server.sql_server.administrator_login
      SQLCMDPASSWORD  = azurerm_mssql_server.sql_server.administrator_login_password
      SQL_SCRIPT_DIR  = abspath("${path.module}/sql")
      SQL_SCRIPT_LIST = join(";", local.erp_sql_scripts)
    }
    command = <<-POWERSHELL
      $ErrorActionPreference = "Stop"
      $c = Get-Command sqlcmd -ErrorAction SilentlyContinue | Select-Object -First 1
      $sqlcmd = if ($c) { $c.Source } elseif (Test-Path "C:\Program Files\SqlCmd\sqlcmd.exe") { "C:\Program Files\SqlCmd\sqlcmd.exe" } else { throw "Instale sqlcmd" }
      $a = @("-S", $env:SQL_SERVER, "-d", $env:SQL_DATABASE, "-U", $env:SQL_USER, "-b", "-r", "1", "-l", "30")
      $ok = $false
      for ($i = 1; $i -le 12; $i++) {
        & $sqlcmd @a -Q "SELECT 1;" *> $null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $ok) { throw "No se pudo conectar a la base ERP" }
      foreach ($s in $env:SQL_SCRIPT_LIST.Split(";")) {
        Write-Host "Ejecutando $s"
        & $sqlcmd @a -i (Join-Path $env:SQL_SCRIPT_DIR $s)
        if ($LASTEXITCODE -ne 0) { throw "Fallo $s" }
      }
    POWERSHELL
  }
}
resource "azurerm_data_factory" "adf" {
  name                = "adf-ucb-transporte-us-ale2026"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "eastus"
}