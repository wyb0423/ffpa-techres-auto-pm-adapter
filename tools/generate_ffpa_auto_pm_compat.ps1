param(
    [string]$GameRoot = 'C:\SteamLibrary\steamapps\common\Victoria 3\game',
    [string]$WorkshopRoot = 'C:\SteamLibrary\steamapps\workshop\content\529340',
    [string]$TechResId = '3472248460',
    [string]$AutoPmId = '3353797125',
    [string]$AutoAutomationId = '3344726320',
    [string]$OutputRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Get-TopBlocks {
    param([string]$Path, [string]$Kind)

    $text = Get-Content -LiteralPath $Path -Raw
    $text = [regex]::Replace($text, '(?m)#.*$', '')
    $pattern = "(?m)^\s*((?:(?:INJECT|REPLACE|REPLACE_OR_CREATE):)?${Kind}_[A-Za-z0-9_-]+)\s*=\s*\{"
    foreach ($match in [regex]::Matches($text, $pattern)) {
        $open = $text.IndexOf('{', $match.Index)
        $depth = 0
        $end = $open
        for ($i = $open; $i -lt $text.Length; $i++) {
            if ($text[$i] -eq '{') { $depth++ }
            elseif ($text[$i] -eq '}') {
                $depth--
                if ($depth -eq 0) { $end = $i; break }
            }
        }
        [pscustomobject]@{
            RawKey = $match.Groups[1].Value
            Key = ($match.Groups[1].Value -replace '^(INJECT|REPLACE|REPLACE_OR_CREATE):', '')
            Body = $text.Substring($open + 1, $end - $open - 1)
            Path = $Path
        }
    }
}

function Get-ListIds {
    param([string]$Body, [string]$Field, [string]$Prefix)

    $match = [regex]::Match($Body, "(?s)\b${Field}\s*=\s*\{(.*?)\}")
    if (-not $match.Success) { return @() }
    @([regex]::Matches($match.Groups[1].Value, "\b${Prefix}[A-Za-z0-9_-]+\b") | ForEach-Object Value)
}

function Read-Database {
    param([string]$Directory, [string]$Kind)

    $database = [ordered]@{}
    Get-ChildItem -LiteralPath $Directory -Filter '*.txt' | Sort-Object FullName | ForEach-Object {
        Get-TopBlocks -Path $_.FullName -Kind $Kind | ForEach-Object {
            $database[$_.Key] = $_
        }
    }
    $database
}

function Apply-Operations {
    param(
        [System.Collections.IDictionary]$Base,
        [string]$Directory,
        [string]$Kind,
        [string]$ListField,
        [string]$ListPrefix
    )

    $result = [ordered]@{}
    foreach ($key in $Base.Keys) {
        $result[$key] = [pscustomobject]@{
            Body = $Base[$key].Body
            Items = @(Get-ListIds -Body $Base[$key].Body -Field $ListField -Prefix $ListPrefix)
        }
    }

    Get-ChildItem -LiteralPath $Directory -Filter '*.txt' | Sort-Object FullName | ForEach-Object {
        Get-TopBlocks -Path $_.FullName -Kind $Kind | ForEach-Object {
            $items = @(Get-ListIds -Body $_.Body -Field $ListField -Prefix $ListPrefix)
            if ($_.RawKey -like 'INJECT:*') {
                $old = @()
                if ($result.Contains($_.Key)) { $old = @($result[$_.Key].Items) }
                $result[$_.Key] = [pscustomobject]@{
                    Body = if ($result.Contains($_.Key)) { $result[$_.Key].Body + "`n" + $_.Body } else { $_.Body }
                    Items = @($old + $items | Select-Object -Unique)
                }
            }
            else {
                $result[$_.Key] = [pscustomobject]@{ Body = $_.Body; Items = $items }
            }
        }
    }
    $result
}

function Get-Goods {
    param([string]$Body, [string]$Direction)
    @([regex]::Matches($Body, "\bgoods_${Direction}_([A-Za-z0-9_]+)_add\s*=") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}

function Get-GoodsAmounts {
    param([string]$Body, [string]$Direction)

    $amounts = [ordered]@{}
    $pattern = "\bgoods_${Direction}_([A-Za-z0-9_]+)_add\s*=\s*(-?[0-9]+(?:\.[0-9]+)?)"
    foreach ($match in [regex]::Matches($Body, $pattern)) {
        $good = $match.Groups[1].Value
        $amount = [decimal]::Parse($match.Groups[2].Value, [Globalization.CultureInfo]::InvariantCulture)
        if (-not $amounts.Contains($good)) { $amounts[$good] = [decimal]0 }
        $amounts[$good] += $amount
    }
    $amounts
}

function Get-IncreasedGoods {
    param(
        [System.Collections.IDictionary]$Source,
        [System.Collections.IDictionary]$Target
    )

    $goods = [System.Collections.Generic.List[string]]::new()
    foreach ($good in @($Source.Keys + $Target.Keys | Select-Object -Unique)) {
        $sourceAmount = if ($Source.Contains($good)) { [decimal]$Source[$good] } else { [decimal]0 }
        $targetAmount = if ($Target.Contains($good)) { [decimal]$Target[$good] } else { [decimal]0 }
        if ($targetAmount -gt $sourceAmount) { $goods.Add($good) }
    }
    @($goods)
}

function Get-SafeKey {
    param([string]$Value)
    ($Value -replace '[^A-Za-z0-9_]', '_')
}

function Add-Line {
    param([System.Text.StringBuilder]$Builder, [int]$Indent, [string]$Text = '')
    [void]$Builder.Append(("`t" * $Indent) + $Text + "`r`n")
}

function Add-OrderedBuildingGuard {
    param(
        [string]$Body,
        [string]$Guard
    )

    # Upstream Auto-Apply PM effects select the building instance through their
    # first ordered_scope_building/limit block. Keep the authored decision tree
    # intact for unadapted instances, while the generated bidirectional manager
    # becomes the sole authority for every production chain it fully covers.
    $orderedLimit = [regex]::new('(?s)\bordered_scope_building\s*=\s*\{\s*limit\s*=\s*\{')
    $match = $orderedLimit.Match($Body)
    if (-not $match.Success) {
        throw "Could not find ordered_scope_building limit while adding guard $Guard"
    }

    $insertAt = $match.Index + $match.Length
    $Body.Insert($insertAt, "`r`n`t`t`tNOT = { $Guard = yes }")
}

function Get-PriceLines {
    param(
        [string[]]$Inputs,
        [string[]]$Outputs,
        [int]$Indent,
        [bool]$CheckOutput = $true,
        [string]$InputThreshold = 'ffpa_auto_pm_upgrade_input_price'
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($good in $Inputs) {
        $lines.Add(("`t" * $Indent) + "sg:${good} = { state_goods_pricier < $InputThreshold }")
    }
    if ($CheckOutput -and $Outputs.Count -eq 1) {
        $lines.Add(("`t" * $Indent) + "sg:$($Outputs[0]) = { state_goods_pricier > ffpa_auto_pm_output_price_floor }")
    }
    elseif ($CheckOutput -and $Outputs.Count -gt 1) {
        $lines.Add(("`t" * $Indent) + 'OR = {')
        foreach ($good in $Outputs) {
            $lines.Add(("`t" * ($Indent + 1)) + "sg:${good} = { state_goods_pricier > ffpa_auto_pm_output_price_floor }")
        }
        $lines.Add(("`t" * $Indent) + '}')
    }
    $lines
}

$techRoot = Join-Path $WorkshopRoot $TechResId
$autoPmRoot = Join-Path $WorkshopRoot $AutoPmId
$autoAutomationRoot = Join-Path $WorkshopRoot $AutoAutomationId

$baseBuildings = Read-Database -Directory (Join-Path $GameRoot 'common\buildings') -Kind 'building'
$basePmgs = Read-Database -Directory (Join-Path $GameRoot 'common\production_method_groups') -Kind 'pmg'
$basePms = Read-Database -Directory (Join-Path $GameRoot 'common\production_methods') -Kind 'pm'

$buildings = Apply-Operations -Base $baseBuildings -Directory (Join-Path $techRoot 'common\buildings') -Kind 'building' -ListField 'production_method_groups' -ListPrefix 'pmg_'
$pmgs = Apply-Operations -Base $basePmgs -Directory (Join-Path $techRoot 'common\production_method_groups') -Kind 'pmg' -ListField 'production_methods' -ListPrefix 'pm_'

$pmBodies = [ordered]@{}
foreach ($key in $basePms.Keys) { $pmBodies[$key] = $basePms[$key].Body }
$newPmIds = [System.Collections.Generic.HashSet[string]]::new()
Get-ChildItem -LiteralPath (Join-Path $techRoot 'common\production_methods') -Filter '*.txt' | Sort-Object FullName | ForEach-Object {
    Get-TopBlocks -Path $_.FullName -Kind 'pm' | ForEach-Object {
        if (-not $basePms.Contains($_.Key)) { [void]$newPmIds.Add($_.Key) }
        $pmBodies[$_.Key] = $_.Body
    }
}

$newBuildingCategories = [ordered]@{
    building_advancedores_mine = 'ffpa_auto_pm_resources'
    building_bauxite_mine = 'ffpa_auto_pm_resources'
    building_commonores_mine = 'ffpa_auto_pm_resources'
    building_copper_mine = 'ffpa_auto_pm_resources'
    building_rare_earths_mine = 'ffpa_auto_pm_resources'
    building_uranium_mine = 'ffpa_auto_pm_resources'
    building_natural_gas_rig = 'ffpa_auto_pm_resources'
    building_hydroponic = 'ffpa_auto_pm_agriculture_water'
    building_water_plant = 'ffpa_auto_pm_agriculture_water'
    building_alloys_plant = 'ffpa_auto_pm_chemicals_materials'
    building_battery_plant = 'ffpa_auto_pm_chemicals_materials'
    building_pharmaceuticals_industry = 'ffpa_auto_pm_chemicals_materials'
    building_mendelejew_hydrogenation_plants = 'ffpa_auto_pm_chemicals_materials'
    building_mendelejew_synthetic_rubber_factory = 'ffpa_auto_pm_chemicals_materials'
    building_robotics_industry = 'ffpa_auto_pm_machinery_aerospace'
    building_aircraft_industry = 'ffpa_auto_pm_machinery_aerospace'
    building_processors_foundry = 'ffpa_auto_pm_electronics_hardware'
    building_electronics_industry = 'ffpa_auto_pm_electronics_hardware'
    building_computer_assembly_plant = 'ffpa_auto_pm_electronics_hardware'
    building_consumer_electronics_industry = 'ffpa_auto_pm_electronics_hardware'
    building_software_industry = 'ffpa_auto_pm_digital'
    building_datacenter_industry = 'ffpa_auto_pm_digital'
    building_telecommunications_industry = 'ffpa_auto_pm_digital'
    building_interactive_media_industry = 'ffpa_auto_pm_digital'
    building_office = 'ffpa_auto_pm_business_logistics'
    building_ecommerce_logistics = 'ffpa_auto_pm_business_logistics'
    building_hydroelectric_power_plant = 'ffpa_auto_pm_energy'
    building_geothermal_power_plant = 'ffpa_auto_pm_energy'
    building_renewable_energy_power_plant = 'ffpa_auto_pm_energy'
    building_fusion_power_plant = 'ffpa_auto_pm_energy'
    building_airport = 'ffpa_auto_pm_transport_urban'
    building_elgar_opera = 'ffpa_auto_pm_culture'
    building_instrument_workshops = 'ffpa_auto_pm_culture'
    building_manzoni_publishing_industry = 'ffpa_auto_pm_culture'
    building_research_center = 'ffpa_auto_pm_research'
}

$nonEconomicBuildings = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    'building_airport', 'building_research_center', 'building_government_administration',
    'building_university', 'building_port', 'building_construction_sector',
    'building_power_grid_station', 'building_nuclear_weapons_silo', 'building_modern_state_baseline'
))

# These upstream Auto-Apply PM building types need full bidirectional handling
# even when Tech & Res only adds automation groups rather than an ordinary PM.
$forcedBidirectionalProductionBuildings = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    'building_explosives_factory'
))

$farmBuildings = @('building_rye_farm','building_wheat_farm','building_rice_farm','building_maize_farm','building_millet_farm')
$mineBuildings = @('building_coal_mine','building_iron_mine','building_lead_mine','building_sulfur_mine','building_gold_mine')
$plantationBuildings = @('building_coffee_plantation','building_cotton_plantation','building_dye_plantation','building_opium_plantation','building_tea_plantation','building_tobacco_plantation','building_sugar_plantation','building_banana_plantation','building_silk_plantation','building_vineyard','building_rubber_plantation')

$autoPmEffects = [ordered]@{}
$autoPmEffectBodies = [ordered]@{}
Get-ChildItem -LiteralPath (Join-Path $autoPmRoot 'common\scripted_effects') -Filter '*.txt' | Sort-Object FullName | ForEach-Object {
    Get-TopBlocks -Path $_.FullName -Kind 'zw_effect' | ForEach-Object {
        $autoPmEffectBodies[$_.Key] = $_.Body
        $buildingMatch = [regex]::Match($_.Body, '\bis_building_type\s*=\s*(building_[A-Za-z0-9_]+)')
        if ($buildingMatch.Success) {
            $autoPmEffects[$buildingMatch.Groups[1].Value] = $_.Key
        }
    }
}

$autoAutomationEffectBodies = [ordered]@{}
Get-ChildItem -LiteralPath (Join-Path $autoAutomationRoot 'common\scripted_effects') -Filter '*.txt' | Sort-Object FullName | ForEach-Object {
    Get-TopBlocks -Path $_.FullName -Kind 'zw_effect' | ForEach-Object {
        $autoAutomationEffectBodies[$_.Key] = $_.Body
    }
}

# The automation mod does not consistently use "automation" in PMG names.
# Treat its authored target PMs as the source of truth so tractors, refrigerated
# storage, logging/oil transport, fences, tools, and similar chains stay under
# the automation/transportation log rather than the ordinary-production log.
$upstreamAutomationPmIds = [System.Collections.Generic.HashSet[string]]::new()
$upstreamTransportationPmIds = [System.Collections.Generic.HashSet[string]]::new()
$upstreamAutomationBuildingPmPairs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($match in [regex]::Matches($autoAutomationEffectBodies['zw_effect_auto_pm_automation'], '\bproduction_method\s*=\s*(pm_[A-Za-z0-9_-]+)')) {
    [void]$upstreamAutomationPmIds.Add($match.Groups[1].Value)
}
foreach ($match in [regex]::Matches($autoAutomationEffectBodies['zw_effect_auto_pm_transportation'], '\bproduction_method\s*=\s*(pm_[A-Za-z0-9_-]+)')) {
    [void]$upstreamTransportationPmIds.Add($match.Groups[1].Value)
}
foreach ($effectName in @('zw_effect_auto_pm_automation','zw_effect_auto_pm_transportation')) {
    foreach ($block in [regex]::Matches($autoAutomationEffectBodies[$effectName], '(?s)\bactivate_production_method\s*=\s*\{(.*?)\}')) {
        $buildingMatch = [regex]::Match($block.Groups[1].Value, '\bbuilding_type\s*=\s*(building_[A-Za-z0-9_-]+)')
        $methodMatch = [regex]::Match($block.Groups[1].Value, '\bproduction_method\s*=\s*(pm_[A-Za-z0-9_-]+)')
        if ($buildingMatch.Success -and $methodMatch.Success) {
            [void]$upstreamAutomationBuildingPmPairs.Add("$($buildingMatch.Groups[1].Value)|$($methodMatch.Groups[1].Value)")
        }
    }
}

function Get-ExistingGate([string]$Building) {
    if ($farmBuildings -contains $Building) { return 'zw_var_auto_pm_building_group_farms' }
    if ($mineBuildings -contains $Building) { return 'zw_var_auto_pm_building_group_mines' }
    if ($plantationBuildings -contains $Building) { return 'zw_var_auto_pm_building_group_plantations' }
    $effect = $autoPmEffects[$Building]
    if ($effect) {
        $candidate = $effect -replace '^zw_effect_auto_pm_', 'zw_var_auto_pm_'
        return $candidate
    }
    $null
}

function Test-IsAutomationGroup([string]$Pmg) {
    $Pmg -match 'automation|data_optimization|data_transportation|^pmg_transportation_building_natural_gas_rig$|^pmg_transport_building_ecommerce_logistics$|^pmg_transport_infrastructure_building_railway$'
}

function Test-IsAutomationPmg {
    param([string]$Pmg, [string[]]$Methods)

    if (Test-IsAutomationGroup $Pmg) { return $true }
    foreach ($method in $Methods) {
        if ($upstreamAutomationPmIds.Contains($method) -or $upstreamTransportationPmIds.Contains($method)) {
            return $true
        }
    }
    $false
}

function Test-IsTransportPmg {
    param([string]$Pmg, [string[]]$Methods)

    if ($Pmg -match 'train_automation|transportation|transport_automation|transport_infrastructure|transport_building|data_transportation') {
        return $true
    }
    foreach ($method in $Methods) {
        if ($upstreamTransportationPmIds.Contains($method)) { return $true }
    }
    $false
}

function Test-IsSpecializationGroup([string]$Pmg) {
    $Pmg -match 'ownership|military|training|conscription|secondary|specialization|production_focus|product_focus|byproduct'
}

function Get-AutomationGate {
    param(
        [string]$Pmg,
        [string]$Candidate,
        [string[]]$Inputs,
        [bool]$Down,
        [bool]$Transport
    )

    if ($Transport) { return 'zw_var_auto_pm_transportation' }
    if ($Down) { return 'zw_var_auto_pm_automation_basic' }

    $needsOil = @($Inputs | Where-Object { $_ -in @('oil','lubricant','heavy_fuel','light_fuel','gas') }).Count -gt 0
    $needsElectric = $Pmg -match 'data_optimization' -or
        $Inputs -contains 'electricity' -or $Inputs -contains 'global_electricity' -or
        $Candidate -match 'electric|robot|iot|internet|digital|advanced_assembly|ai_|algorithm|cnc|photolithography|smart_grid|drone|computer|surface_mount|automated_hydro|closed_loop'
    if ($needsOil -and $needsElectric) { return 'zw_var_auto_pm_automation_electric+zw_var_auto_pm_automation_oil' }
    if ($needsOil) { return 'zw_var_auto_pm_automation_oil' }
    if ($needsElectric) { return 'zw_var_auto_pm_automation_electric' }
    'zw_var_auto_pm_automation_basic'
}

$transitions = [System.Collections.Generic.List[object]]::new()
$additionalTransitions = [System.Collections.Generic.List[object]]::new()
$transitionKeys = [System.Collections.Generic.HashSet[string]]::new()
$productionBuildings = [System.Collections.Generic.HashSet[string]]::new()
$automationBuildings = [System.Collections.Generic.HashSet[string]]::new()
$activeAutomationPmgs = [System.Collections.Generic.HashSet[string]]::new()

function New-AutoPmTransition {
    param(
        [string]$Building,
        [string]$Pmg,
        [string]$Previous,
        [string]$Candidate,
        [ValidateSet('up','down')][string]$Direction,
        [string]$Gate,
        [bool]$Automation,
        [bool]$Transport,
        [bool]$CheckProductivity,
        [bool]$Legacy
    )

    $sourceInputAmounts = Get-GoodsAmounts -Body $pmBodies[$Previous] -Direction 'input'
    $targetInputAmounts = Get-GoodsAmounts -Body $pmBodies[$Candidate] -Direction 'input'
    $sourceOutputAmounts = Get-GoodsAmounts -Body $pmBodies[$Previous] -Direction 'output'
    $targetOutputAmounts = Get-GoodsAmounts -Body $pmBodies[$Candidate] -Direction 'output'
    $increasedInputs = @(Get-IncreasedGoods -Source $sourceInputAmounts -Target $targetInputAmounts)
    $reducedInputs = @(Get-IncreasedGoods -Source $targetInputAmounts -Target $sourceInputAmounts)
    $increasedOutputs = @(Get-IncreasedGoods -Source $sourceOutputAmounts -Target $targetOutputAmounts)
    $reducedOutputs = @(Get-IncreasedGoods -Source $targetOutputAmounts -Target $sourceOutputAmounts)

    # Fall back to presence-only parsing for scripted/non-literal amounts.
    if ($increasedInputs.Count -eq 0 -and $Direction -eq 'up') {
        $increasedInputs = @(Get-Goods -Body $pmBodies[$Candidate] -Direction 'input')
    }
    if ($increasedOutputs.Count -eq 0 -and $Direction -eq 'up') {
        $increasedOutputs = @(Get-Goods -Body $pmBodies[$Candidate] -Direction 'output')
    }

    [pscustomobject]@{
        Key = Get-SafeKey "${Building}__${Pmg}__${Previous}__${Candidate}"
        Building = $Building
        Pmg = $Pmg
        Previous = $Previous
        Candidate = $Candidate
        Direction = $Direction
        Inputs = $increasedInputs
        Outputs = $increasedOutputs
        PressureInputs = $reducedInputs
        ReducedOutputs = $reducedOutputs
        Gate = $Gate
        Automation = $Automation
        Transport = if ($Automation) { $Transport } else { $false }
        Observation = if ($Automation) { 'ffpa_auto_pm_automation_observation_months' } else { 'ffpa_auto_pm_production_observation_months' }
        CheckProductivity = $CheckProductivity
        Legacy = $Legacy
    }
}

foreach ($building in $buildings.Keys) {
    $isNewManaged = $newBuildingCategories.Contains($building)
    $isExistingManaged = $autoPmEffects.Contains($building) -or $farmBuildings -contains $building -or $mineBuildings -contains $building -or $plantationBuildings -contains $building
    $buildingPmgs = @($buildings[$building].Items | Where-Object { $pmgs.Contains($_) })
    $hasManagedAutomation = $false
    $hasManagedProduction = $false
    foreach ($buildingPmg in $buildingPmgs) {
        $buildingMethods = @($pmgs[$buildingPmg].Items)
        foreach ($method in $buildingMethods) {
            if (-not $newPmIds.Contains($method)) { continue }
            if (Test-IsAutomationPmg -Pmg $buildingPmg -Methods $buildingMethods) { $hasManagedAutomation = $true }
            else { $hasManagedProduction = $true }
            break
        }
    }

    foreach ($pmg in $buildingPmgs) {
        $methods = @($pmgs[$pmg].Items)
        if ($methods.Count -lt 2) { continue }
        $isAutomation = Test-IsAutomationPmg -Pmg $pmg -Methods $methods
        $isTransport = $isAutomation -and (Test-IsTransportPmg -Pmg $pmg -Methods $methods)
        if ($isAutomation) {
            if (-not $hasManagedAutomation) { continue }
            [void]$automationBuildings.Add($building)
            [void]$activeAutomationPmgs.Add($pmg)
        }
        elseif (-not ($isNewManaged -or ($isExistingManaged -and ($hasManagedProduction -or $forcedBidirectionalProductionBuildings.Contains($building))))) { continue }
        elseif ($pmg -match 'ownership|training|conscription') { continue }

        $productionGate = if ($isNewManaged) { $newBuildingCategories[$building] } else { Get-ExistingGate $building }
        if (-not $isAutomation -and -not $productionGate) { continue }
        if (-not $isAutomation) { [void]$productionBuildings.Add($building) }
        $checkProductivity = -not $nonEconomicBuildings.Contains($building)
        $allowDown = $checkProductivity -and -not (Test-IsSpecializationGroup $pmg)

        for ($index = 1; $index -lt $methods.Count; $index++) {
            $lower = $methods[$index - 1]
            $upper = $methods[$index]
            if (-not $pmBodies.Contains($lower) -or -not $pmBodies.Contains($upper)) { continue }

            $upperInputs = @(Get-Goods -Body $pmBodies[$upper] -Direction 'input')
            $upGate = if ($isAutomation) { Get-AutomationGate -Pmg $pmg -Candidate $upper -Inputs $upperInputs -Down $false -Transport $isTransport } else { $productionGate }
            $upTransition = New-AutoPmTransition -Building $building -Pmg $pmg -Previous $lower -Candidate $upper -Direction up -Gate $upGate -Automation $isAutomation -Transport $isTransport -CheckProductivity $checkProductivity -Legacy $false
            $edgeKey = "${building}|${pmg}|${lower}|${upper}"

            # Preserve the exact legacy-forward ordering so live saves keep the
            # meaning of existing t#### workflow markers.
            $legacyEligible = if ($pmg -match 'ownership|military|training|conscription') {
                $false
            }
            elseif ($isAutomation) {
                $newPmIds.Contains($upper)
            }
            else {
                $isNewManaged -or $newPmIds.Contains($upper)
            }
            if ($legacyEligible) {
                $upTransition.Legacy = $true
                $transitions.Add($upTransition)
                [void]$transitionKeys.Add($edgeKey)
            }
            elseif ($transitionKeys.Add($edgeKey)) {
                $additionalTransitions.Add($upTransition)
            }

            if ($allowDown) {
                $lowerInputs = @(Get-Goods -Body $pmBodies[$lower] -Direction 'input')
                $downGate = if ($isAutomation) { Get-AutomationGate -Pmg $pmg -Candidate $lower -Inputs $lowerInputs -Down $true -Transport $isTransport } else { $productionGate }
                $downTransition = New-AutoPmTransition -Building $building -Pmg $pmg -Previous $upper -Candidate $lower -Direction down -Gate $downGate -Automation $isAutomation -Transport $isTransport -CheckProductivity $checkProductivity -Legacy $false
                $additionalTransitions.Add($downTransition)
            }
        }
    }
}

foreach ($transition in $additionalTransitions) { $transitions.Add($transition) }

$edgeIdentities = [System.Collections.Generic.HashSet[string]]::new()
foreach ($transition in $transitions) {
    $identity = "$($transition.Building)|$($transition.Pmg)|$($transition.Previous)|$($transition.Candidate)"
    if (-not $edgeIdentities.Add($identity)) { throw "Duplicate generated transition: $identity" }
}
foreach ($transition in @($transitions | Where-Object Direction -eq 'down')) {
    $reverseIdentity = "$($transition.Building)|$($transition.Pmg)|$($transition.Candidate)|$($transition.Previous)"
    if (-not $edgeIdentities.Contains($reverseIdentity)) { throw "Downward transition has no upward reverse: $reverseIdentity" }
}

$coveredAutomationBuildingPmPairs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($transition in @($transitions | Where-Object Automation)) {
    [void]$coveredAutomationBuildingPmPairs.Add("$($transition.Building)|$($transition.Previous)")
    [void]$coveredAutomationBuildingPmPairs.Add("$($transition.Building)|$($transition.Candidate)")
}
$missingUpstreamAutomationPairs = @($upstreamAutomationBuildingPmPairs | Where-Object { -not $coveredAutomationBuildingPmPairs.Contains($_) } | Sort-Object)
if ($missingUpstreamAutomationPairs.Count) {
    throw "Upstream automation building/PM pairs misclassified or uncovered: $($missingUpstreamAutomationPairs -join ', ')"
}
$explosivesProductionTransitions = @($transitions | Where-Object { $_.Building -eq 'building_explosives_factory' -and -not $_.Automation })
if (-not ($explosivesProductionTransitions | Where-Object Direction -eq 'up') -or -not ($explosivesProductionTransitions | Where-Object Direction -eq 'down')) {
    throw 'Explosives factory ordinary production chain is not covered in both directions'
}

# Clausewitz variable identifiers are kept deliberately short.  The descriptive
# transition key is retained in the coverage report, while runtime flags use a
# stable sequence generated from the deterministically parsed database order.
$transitionIndex = 0
foreach ($transition in $transitions) {
    $transitionIndex++
    $transition | Add-Member -NotePropertyName VarKey -NotePropertyValue ('t{0:D4}' -f $transitionIndex)
}

# Building scopes cannot store variables in Victoria 3 1.13.  Each state has at
# most one building object of a given type, so workflow state can safely live on
# the state when its variable names are namespaced by building type.  Short,
# deterministic keys keep the generated Clausewitz identifiers manageable.
$buildingWorkflowKeys = [ordered]@{}
$buildingIndex = 0
foreach ($building in ($transitions.Building | Sort-Object -Unique)) {
    $buildingIndex++
    $buildingWorkflowKeys[$building] = ('b{0:D3}' -f $buildingIndex)
}
foreach ($transition in $transitions) {
    $transition | Add-Member -NotePropertyName WorkflowKey -NotePropertyValue $buildingWorkflowKeys[$transition.Building]
}

$groupWorkflowKeys = [ordered]@{}
$groupIndex = 0
foreach ($groupIdentity in @($transitions | ForEach-Object { "$($_.Building)|$($_.Pmg)" } | Sort-Object -Unique)) {
    $groupIndex++
    $groupWorkflowKeys[$groupIdentity] = ('g{0:D4}' -f $groupIndex)
}
foreach ($transition in $transitions) {
    $groupIdentity = "$($transition.Building)|$($transition.Pmg)"
    $transition | Add-Member -NotePropertyName GroupKey -NotePropertyValue $groupWorkflowKeys[$groupIdentity]
}

# Per-building transition selectors.
$effects = [System.Text.StringBuilder]::new()
Add-Line $effects 0 '# Generated from the installed Victoria 3 and Tech & Res databases.'
Add-Line $effects 0 '# Do not edit manually; regenerate with tools/generate_ffpa_auto_pm_compat.ps1.'
Add-Line $effects 0

foreach ($building in ($transitions.Building | Sort-Object -Unique)) {
    $workflowKey = $buildingWorkflowKeys[$building]
    $pendingVar = "ffpa_ap_${workflowKey}_pending"
    $pendingMonthsVar = "ffpa_ap_${workflowKey}_pending_months"
    $trialVar = "ffpa_ap_${workflowKey}_trial"
    foreach ($mode in @('production', 'automation')) {
        $modeTransitions = if ($mode -eq 'automation') {
            @($transitions | Where-Object { $_.Building -eq $building -and $_.Automation })
        }
        else {
            @($transitions | Where-Object { $_.Building -eq $building -and -not $_.Automation })
        }
        $modeTransitions = @($modeTransitions | Sort-Object @{ Expression = { if ($_.Direction -eq 'down') { 0 } else { 1 } } }, VarKey)
        if ($modeTransitions.Count -eq 0) { continue }

        Add-Line $effects 0 "ffpa_try_${building}_${mode}_transition = {"
        $branch = 'if'
        foreach ($transition in $modeTransitions) {
            $groupCooldownVar = "ffpa_ap_${workflowKey}_$($transition.GroupKey)_cooldown"
            $oscillationLockVar = "ffpa_ap_${workflowKey}_$($transition.GroupKey)_osc_lock"
            $manualLockVar = "ffpa_ap_${workflowKey}_manual_lock"
            Add-Line $effects 1 "$branch = {"
            Add-Line $effects 2 'limit = {'
            Add-Line $effects 3 'owner = {'
            foreach ($gateVariable in ($transition.Gate -split '\+')) { Add-Line $effects 4 "has_variable = $gateVariable" }
            Add-Line $effects 3 '}'
            Add-Line $effects 3 'state = {'
            Add-Line $effects 4 "NOT = { has_variable = $pendingVar }"
            Add-Line $effects 4 "NOT = { has_variable = $trialVar }"
            Add-Line $effects 4 "NOT = { has_variable = $manualLockVar }"
            Add-Line $effects 4 "NOT = { has_variable = $groupCooldownVar }"
            Add-Line $effects 4 "NOT = { has_variable = $oscillationLockVar }"
            Add-Line $effects 3 '}'
            Add-Line $effects 3 "has_active_production_method = $($transition.Previous)"
            Add-Line $effects 3 'state = {'
            Add-Line $effects 4 'can_activate_production_method = {'
            Add-Line $effects 5 "building_type = $building"
            Add-Line $effects 5 "production_method = $($transition.Candidate)"
            Add-Line $effects 4 '}'
            Add-Line $effects 3 '}'
            if ($transition.Direction -eq 'up') {
                if ($transition.Automation -and -not $transition.Transport) { Add-Line $effects 3 'state = { zw_trigger_aaap_state_workforce_low = yes }' }
                if ($transition.CheckProductivity) { Add-Line $effects 3 'cash_reserves_ratio > ffpa_auto_pm_low_cash_reserves' }
                Add-Line $effects 3 'state = {'
                foreach ($line in (Get-PriceLines -Inputs $transition.Inputs -Outputs $transition.Outputs -Indent 4 -CheckOutput $transition.CheckProductivity)) { [void]$effects.Append($line + "`r`n") }
                Add-Line $effects 3 '}'
            }
            else {
                Add-Line $effects 3 'OR = {'
                if ($transition.Automation) {
                    Add-Line $effects 4 'state = { NOT = { zw_trigger_aaap_state_workforce_low = yes } }'
                }
                else {
                    Add-Line $effects 4 'AND = { weekly_profit <= 0 is_subsidized = no }'
                    Add-Line $effects 4 'cash_reserves_ratio <= ffpa_auto_pm_low_cash_reserves'
                }
                foreach ($good in $transition.PressureInputs) { Add-Line $effects 4 "state = { sg:${good} = { state_goods_pricier > ffpa_auto_pm_downgrade_input_price } }" }
                Add-Line $effects 3 '}'
                foreach ($good in $transition.ReducedOutputs) { Add-Line $effects 3 "state = { sg:${good} = { state_goods_pricier < ffpa_auto_pm_downgrade_output_ceiling } }" }
            }
            Add-Line $effects 2 '}'
            Add-Line $effects 2 'state = {'
            Add-Line $effects 3 "set_variable = $pendingVar"
            Add-Line $effects 3 "set_variable = { name = $pendingMonthsVar value = 0 }"
            Add-Line $effects 3 "set_variable = ffpa_pending_$($transition.VarKey)"
            Add-Line $effects 2 '}'
            Add-Line $effects 2 ('debug_log = "FFPA_PM|{0}_CANDIDATE|{1}|{2}|{3}|{4}->{5}"' -f $transition.Direction.ToUpperInvariant(), $transition.VarKey, $building, $transition.Pmg, $transition.Previous, $transition.Candidate)
            Add-Line $effects 1 '}'
            $branch = 'else_if'
        }
        Add-Line $effects 0 '}'
        Add-Line $effects 0
    }
}

# Country entry points for new buildings and extension calls for existing handlers.
Add-Line $effects 0 'ffpa_process_new_techres_buildings = {'
$newBuildingCategoryBuckets = [ordered]@{}
$categoryIndex = 0
foreach ($category in ($newBuildingCategories.Values | Sort-Object -Unique)) {
    $newBuildingCategoryBuckets[$category] = $categoryIndex % 6
    $categoryIndex++
}
foreach ($building in ($newBuildingCategories.Keys | Where-Object { $productionBuildings.Contains($_) })) {
    $category = $newBuildingCategories[$building]
    $monthA = $newBuildingCategoryBuckets[$category]
    $monthB = $monthA + 6
    Add-Line $effects 1 'if = {'
    Add-Line $effects 2 'limit = {'
    Add-Line $effects 3 "has_variable = $category"
    Add-Line $effects 3 'OR = {'
    Add-Line $effects 4 'has_variable = zw_var_auto_pm_higher_frequency'
    Add-Line $effects 4 "month = $monthA"
    Add-Line $effects 4 "month = $monthB"
    Add-Line $effects 3 '}'
    Add-Line $effects 2 '}'
    Add-Line $effects 2 'ordered_scope_building = {'
    Add-Line $effects 3 "limit = { is_building_type = $building level >= 1 ffpa_can_${building}_production_transition = yes }"
    Add-Line $effects 3 'order_by = { subtract = level }'
    Add-Line $effects 3 'min = 0'
    Add-Line $effects 3 'max = { value = scope:ffpa_scope_auto_pm_num }'
    Add-Line $effects 3 'check_range_bounds = no'
    Add-Line $effects 3 "ffpa_try_${building}_production_transition = yes"
    Add-Line $effects 2 '}'
    Add-Line $effects 1 '}'
}
Add-Line $effects 0 '}'
Add-Line $effects 0

foreach ($building in ($productionBuildings | Sort-Object)) {
    if ($newBuildingCategories.Contains($building)) { continue }
    $effectName = $autoPmEffects[$building]
    if (-not $effectName) { continue }
    $workflowKey = $buildingWorkflowKeys[$building]
    $guardName = "ffpa_auto_pm_upstream_guard_${workflowKey}"
    $guardedBody = Add-OrderedBuildingGuard -Body $autoPmEffectBodies[$effectName] -Guard $guardName
    Add-Line $effects 0 "REPLACE:${effectName} = {"
    foreach ($sourceLine in ($guardedBody.Trim() -split "`r?`n")) {
        Add-Line $effects 1 $sourceLine
    }
    Add-Line $effects 1 'if = {'
    Add-Line $effects 2 'limit = { NOT = { has_variable = ffpa_pm_upstream_scan_logged } }'
    Add-Line $effects 2 'debug_log = "FFPA_PM|UPSTREAM_PRODUCTION_SCAN|Auto-Apply PMs scheduler reached adapter"'
    Add-Line $effects 2 'set_variable = { name = ffpa_pm_upstream_scan_logged value = 1 months = 1 }'
    Add-Line $effects 1 '}'
    Add-Line $effects 1 'ordered_scope_building = {'
    Add-Line $effects 2 "limit = { is_building_type = $building level >= 1 ffpa_can_${building}_production_transition = yes }"
    Add-Line $effects 2 'order_by = { subtract = level }'
    Add-Line $effects 2 'min = 0'
    Add-Line $effects 2 'max = { value = scope:zw_scope_auto_pm_num }'
    Add-Line $effects 2 'check_range_bounds = no'
    Add-Line $effects 2 'if = {'
    Add-Line $effects 3 "limit = { $guardName = yes owner = { NOT = { has_variable = ffpa_pm_production_guard_logged } } }"
    Add-Line $effects 3 ('debug_log = "FFPA_PM|PRODUCTION_GUARD|{0}|upstream handler delegated this bidirectionally managed instance"' -f $building)
    Add-Line $effects 3 'owner = { set_variable = { name = ffpa_pm_production_guard_logged value = 1 months = 1 } }'
    Add-Line $effects 2 '}'
    Add-Line $effects 2 "ffpa_try_${building}_production_transition = yes"
    Add-Line $effects 1 '}'
    Add-Line $effects 0 '}'
    Add-Line $effects 0
}

# State entry points used by the Auto-Apply Automation PMs wrapper and by the
# compatibility journal (the latter also reaches new buildings without railways).
Add-Line $effects 0 'ffpa_process_state_techres_automation = {'
Add-Line $effects 1 'ordered_scope_building = {'
Add-Line $effects 2 'limit = {'
Add-Line $effects 3 'level >= 1'
Add-Line $effects 3 'OR = {'
foreach ($building in ($transitions | Where-Object { $_.Automation -and -not $_.Transport } | Select-Object -ExpandProperty Building -Unique | Sort-Object)) {
    Add-Line $effects 4 "AND = { is_building_type = $building ffpa_can_${building}_automation_transition = yes }"
}
Add-Line $effects 3 '}'
Add-Line $effects 2 '}'
Add-Line $effects 2 'order_by = { subtract = level }'
Add-Line $effects 2 'min = 0'
Add-Line $effects 2 'max = 1'
Add-Line $effects 2 'check_range_bounds = no'
foreach ($building in ($transitions | Where-Object { $_.Automation -and -not $_.Transport } | Select-Object -ExpandProperty Building -Unique | Sort-Object)) {
    Add-Line $effects 2 "if = { limit = { is_building_type = $building } ffpa_try_${building}_automation_transition = yes }"
}
Add-Line $effects 1 '}'
Add-Line $effects 0 '}'
Add-Line $effects 0

Add-Line $effects 0 'ffpa_process_state_techres_transportation = {'
Add-Line $effects 1 'ordered_scope_building = {'
Add-Line $effects 2 'limit = {'
Add-Line $effects 3 'level >= 1'
Add-Line $effects 3 'OR = {'
foreach ($building in ($transitions | Where-Object { $_.Automation -and $_.Transport } | Select-Object -ExpandProperty Building -Unique | Sort-Object)) {
    Add-Line $effects 4 "AND = { is_building_type = $building ffpa_can_${building}_automation_transition = yes }"
}
Add-Line $effects 3 '}'
Add-Line $effects 2 '}'
Add-Line $effects 2 'order_by = { subtract = level }'
Add-Line $effects 2 'min = 0'
Add-Line $effects 2 'max = 1'
Add-Line $effects 2 'check_range_bounds = no'
foreach ($building in ($transitions | Where-Object { $_.Automation -and $_.Transport } | Select-Object -ExpandProperty Building -Unique | Sort-Object)) {
    Add-Line $effects 2 "if = { limit = { is_building_type = $building } ffpa_try_${building}_automation_transition = yes }"
}
Add-Line $effects 1 '}'
Add-Line $effects 0 '}'
Add-Line $effects 0

$guardedAutomationBody = Add-OrderedBuildingGuard `
    -Body $autoAutomationEffectBodies['zw_effect_change_state_pm_automation'] `
    -Guard 'ffpa_auto_pm_upstream_automation_guard'
Add-Line $effects 0 'REPLACE:zw_effect_change_state_pm_automation = {'
foreach ($sourceLine in ($guardedAutomationBody.Trim() -split "`r?`n")) {
    Add-Line $effects 1 $sourceLine
}
Add-Line $effects 1 'owner = {'
Add-Line $effects 2 'if = {'
Add-Line $effects 3 'limit = { NOT = { has_variable = ffpa_pm_automation_scan_logged } }'
Add-Line $effects 3 'debug_log = "FFPA_PM|UPSTREAM_AUTOMATION_SCAN|Auto-Apply Automation PMs scheduler reached adapter"'
Add-Line $effects 3 'set_variable = { name = ffpa_pm_automation_scan_logged value = 1 months = 1 }'
Add-Line $effects 2 '}'
Add-Line $effects 1 '}'
Add-Line $effects 1 'if = {'
Add-Line $effects 2 'limit = {'
Add-Line $effects 3 'any_scope_building = { ffpa_auto_pm_upstream_automation_guard = yes }'
Add-Line $effects 3 'owner = { NOT = { has_variable = ffpa_pm_automation_guard_logged } }'
Add-Line $effects 2 '}'
Add-Line $effects 2 'debug_log = "FFPA_PM|AUTOMATION_GUARD|upstream automation handler delegated bidirectionally managed instances"'
Add-Line $effects 2 'owner = { set_variable = { name = ffpa_pm_automation_guard_logged value = 1 months = 1 } }'
Add-Line $effects 1 '}'
Add-Line $effects 1 'ffpa_process_state_techres_automation = yes'
Add-Line $effects 0 '}'
Add-Line $effects 0

$guardedTransportationBody = Add-OrderedBuildingGuard `
    -Body $autoAutomationEffectBodies['zw_effect_change_state_pm_transportation'] `
    -Guard 'ffpa_auto_pm_upstream_transport_guard'
Add-Line $effects 0 'REPLACE:zw_effect_change_state_pm_transportation = {'
foreach ($sourceLine in ($guardedTransportationBody.Trim() -split "`r?`n")) {
    Add-Line $effects 1 $sourceLine
}
Add-Line $effects 1 'owner = {'
Add-Line $effects 2 'if = {'
Add-Line $effects 3 'limit = { NOT = { has_variable = ffpa_pm_transport_scan_logged } }'
Add-Line $effects 3 'debug_log = "FFPA_PM|UPSTREAM_TRANSPORT_SCAN|Auto-Apply Automation PMs transportation scheduler reached adapter"'
Add-Line $effects 3 'set_variable = { name = ffpa_pm_transport_scan_logged value = 1 months = 1 }'
Add-Line $effects 2 '}'
Add-Line $effects 1 '}'
Add-Line $effects 1 'if = {'
Add-Line $effects 2 'limit = {'
Add-Line $effects 3 'any_scope_building = { ffpa_auto_pm_upstream_transport_guard = yes }'
Add-Line $effects 3 'owner = { NOT = { has_variable = ffpa_pm_transport_guard_logged } }'
Add-Line $effects 2 '}'
Add-Line $effects 2 'debug_log = "FFPA_PM|TRANSPORT_GUARD|upstream transportation handler delegated bidirectionally managed instances"'
Add-Line $effects 2 'owner = { set_variable = { name = ffpa_pm_transport_guard_logged value = 1 months = 1 } }'
Add-Line $effects 1 '}'
Add-Line $effects 1 'ffpa_process_state_techres_transportation = yes'
Add-Line $effects 0 '}'
Add-Line $effects 0

# Pending-candidate and live-trial state machine.
$trials = [System.Text.StringBuilder]::new()
Add-Line $trials 0 '# Generated debounce, trial, productivity and rollback state machine.'

function Add-AutoPmSuccessState {
    param(
        [System.Text.StringBuilder]$Builder,
        [int]$Indent,
        [object]$Transition,
        [string]$WorkflowKey
    )

    $groupPrefix = "ffpa_ap_${WorkflowKey}_$($Transition.GroupKey)"
    $lastDirectionVar = "${groupPrefix}_last_$($Transition.Direction)"
    $oppositeDirection = if ($Transition.Direction -eq 'up') { 'down' } else { 'up' }
    $oppositeDirectionVar = "${groupPrefix}_last_${oppositeDirection}"
    $reversalVar = "${groupPrefix}_reversal"
    $oscillationLockVar = "${groupPrefix}_osc_lock"
    $groupCooldownVar = "${groupPrefix}_cooldown"

    Add-Line $Builder $Indent 'state = {'
    Add-Line $Builder ($Indent + 1) 'if = {'
    Add-Line $Builder ($Indent + 2) "limit = { has_variable = $oppositeDirectionVar }"
    Add-Line $Builder ($Indent + 2) 'if = {'
    Add-Line $Builder ($Indent + 3) "limit = { has_variable = $reversalVar }"
    Add-Line $Builder ($Indent + 3) "set_variable = { name = $oscillationLockVar value = 1 months = ffpa_auto_pm_oscillation_lock_months }"
    Add-Line $Builder ($Indent + 3) "remove_variable = $reversalVar"
    Add-Line $Builder ($Indent + 2) '}'
    Add-Line $Builder ($Indent + 2) 'else = {'
    Add-Line $Builder ($Indent + 3) "set_variable = { name = $reversalVar value = 1 months = ffpa_auto_pm_reversal_window_months }"
    Add-Line $Builder ($Indent + 2) '}'
    Add-Line $Builder ($Indent + 1) '}'
    Add-Line $Builder ($Indent + 1) "remove_variable = $oppositeDirectionVar"
    Add-Line $Builder ($Indent + 1) "set_variable = $lastDirectionVar"
    Add-Line $Builder ($Indent + 1) "set_variable = { name = $groupCooldownVar value = 1 months = ffpa_auto_pm_success_cooldown_months }"
    Add-Line $Builder $Indent '}'
    Add-Line $Builder $Indent 'if = {'
    Add-Line $Builder ($Indent + 1) "limit = { state = { has_variable = $oscillationLockVar } }"
    Add-Line $Builder ($Indent + 1) ('debug_log = "FFPA_PM|OSCILLATION_LOCK|{0}|{1}|{2}|configured duration"' -f $Transition.VarKey, $Transition.Building, $Transition.Pmg)
    Add-Line $Builder $Indent '}'
}

function Add-AutoPmCounterIncrement {
    param(
        [System.Text.StringBuilder]$Builder,
        [int]$Indent,
        [string]$CounterVar,
        [string]$OppositeVar
    )

    # change_variable does not create a missing variable reliably.  Keep the
    # increment self-initializing so old saves and partially repaired workflows
    # can still reach the two-check terminal state.
    Add-Line $Builder $Indent 'if = {'
    Add-Line $Builder ($Indent + 1) "limit = { state = { has_variable = $CounterVar } }"
    Add-Line $Builder ($Indent + 1) "state = { change_variable = { name = $CounterVar add = 1 } }"
    Add-Line $Builder $Indent '}'
    Add-Line $Builder $Indent 'else = {'
    Add-Line $Builder ($Indent + 1) "state = { set_variable = { name = $CounterVar value = 1 } }"
    Add-Line $Builder $Indent '}'
    Add-Line $Builder $Indent "state = { remove_variable = $OppositeVar }"
}

# `earnings` is exposed as a building trigger, not as a storable numeric link.
# Capture it into a geometric band using only documented trigger comparisons.
# Acceptance uses the lower boundary of that same band.  This tolerates normal
# within-band noise (at most about a 1.96% decline for ordinary 2% bands) without
# relying on the invalid `value = earnings`.
$productivityThresholds = [System.Collections.Generic.List[decimal]]::new()
$productivityThreshold = [decimal]0.5
$productivityBandMultiplier = [decimal]1.02
while ($productivityThreshold -le [decimal]1000000) {
    $roundedThreshold = [decimal]::Round($productivityThreshold, 4)
    if ($productivityThresholds.Count -eq 0 -or $roundedThreshold -gt $productivityThresholds[$productivityThresholds.Count - 1]) {
        $productivityThresholds.Add($roundedThreshold)
    }
    $productivityThreshold *= $productivityBandMultiplier
}
$capturedProductivityBandCount = $productivityThresholds.Count + 1

Add-Line $trials 0 'ffpa_capture_auto_pm_productivity_band = {'
for ($bandIndex = 0; $bandIndex -lt $productivityThresholds.Count; $bandIndex++) {
    $thresholdText = $productivityThresholds[$bandIndex].ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
    Add-Line $trials 1 "$(if ($bandIndex -eq 0) { 'if' } else { 'else_if' }) = {"
    Add-Line $trials 2 "limit = { earnings < $thresholdText }"
    Add-Line $trials 2 'state = {'
    Add-Line $trials 3 "set_variable = { name = `$BASELINE_VAR`$ value = $bandIndex }"
    Add-Line $trials 2 '}'
    Add-Line $trials 1 '}'
}
Add-Line $trials 1 'else = {'
Add-Line $trials 2 'state = {'
Add-Line $trials 3 "set_variable = { name = `$BASELINE_VAR`$ value = $($productivityThresholds.Count) }"
Add-Line $trials 2 '}'
Add-Line $trials 1 '}'
Add-Line $trials 0 '}'
Add-Line $trials 0

# One cleanup effect per building type keeps concurrent workflows in the same
# state independent while avoiding parameter-heavy calls at every exit path.
foreach ($building in ($transitions.Building | Sort-Object -Unique)) {
    $workflowKey = $buildingWorkflowKeys[$building]
    Add-Line $trials 0 "ffpa_clear_auto_pm_workflow_${workflowKey} = {"
    Add-Line $trials 1 'state = {'
    Add-Line $trials 2 "remove_variable = ffpa_ap_${workflowKey}_pending"
    Add-Line $trials 2 "remove_variable = ffpa_ap_${workflowKey}_pending_months"
    Add-Line $trials 2 "remove_variable = ffpa_ap_${workflowKey}_trial"
    Add-Line $trials 2 "remove_variable = ffpa_ap_${workflowKey}_trial_months"
    Add-Line $trials 2 "remove_variable = ffpa_ap_${workflowKey}_baseline"
    Add-Line $trials 2 "remove_variable = ffpa_ap_${workflowKey}_success_checks"
    Add-Line $trials 2 "remove_variable = ffpa_ap_${workflowKey}_failure_checks"
    Add-Line $trials 1 '}'
    Add-Line $trials 0 '}'
    Add-Line $trials 0
}

Add-Line $trials 0 'ffpa_update_auto_pm_trials = {'
Add-Line $trials 1 'every_scope_building = {'
Add-Line $trials 2 'limit = {'
Add-Line $trials 3 'level >= 1'
Add-Line $trials 3 'OR = {'
foreach ($building in ($transitions.Building | Sort-Object -Unique)) {
    $workflowKey = $buildingWorkflowKeys[$building]
    Add-Line $trials 4 'AND = {'
    Add-Line $trials 5 "is_building_type = $building"
    Add-Line $trials 5 'state = {'
    Add-Line $trials 6 'OR = {'
    Add-Line $trials 7 "has_variable = ffpa_ap_${workflowKey}_pending"
    Add-Line $trials 7 "has_variable = ffpa_ap_${workflowKey}_trial"
    Add-Line $trials 6 '}'
    Add-Line $trials 5 '}'
    Add-Line $trials 4 '}'
}
Add-Line $trials 3 '}'
Add-Line $trials 2 '}'
foreach ($building in ($transitions.Building | Sort-Object -Unique)) {
    $buildingTransitions = @($transitions | Where-Object Building -eq $building)
    $workflowKey = $buildingWorkflowKeys[$building]
    $pendingVar = "ffpa_ap_${workflowKey}_pending"
    $pendingMonthsVar = "ffpa_ap_${workflowKey}_pending_months"
    $trialVar = "ffpa_ap_${workflowKey}_trial"
    $trialMonthsVar = "ffpa_ap_${workflowKey}_trial_months"
    $baselineVar = "ffpa_ap_${workflowKey}_baseline"
    $successVar = "ffpa_ap_${workflowKey}_success_checks"
    $failureVar = "ffpa_ap_${workflowKey}_failure_checks"
    $manualLockVar = "ffpa_ap_${workflowKey}_manual_lock"
    $clearEffect = "ffpa_clear_auto_pm_workflow_${workflowKey}"

    Add-Line $trials 2 'if = {'
    Add-Line $trials 3 "limit = { is_building_type = $building }"
    Add-Line $trials 3 'if = {'
    Add-Line $trials 4 "limit = { state = { has_variable = $pendingVar } }"
    foreach ($transition in $buildingTransitions) {
        $groupCooldownVar = "ffpa_ap_${workflowKey}_$($transition.GroupKey)_cooldown"
        $oscillationLockVar = "ffpa_ap_${workflowKey}_$($transition.GroupKey)_osc_lock"
        Add-Line $trials 4 'if = {'
        Add-Line $trials 5 "limit = { state = { has_variable = ffpa_pending_$($transition.VarKey) } }"
        Add-Line $trials 5 'if = {'
        Add-Line $trials 6 'limit = {'
        Add-Line $trials 7 'owner = {'
        foreach ($gateVariable in ($transition.Gate -split '\+')) { Add-Line $trials 8 "has_variable = $gateVariable" }
        Add-Line $trials 7 '}'
        Add-Line $trials 7 "has_active_production_method = $($transition.Previous)"
        Add-Line $trials 7 'state = {'
        Add-Line $trials 8 'can_activate_production_method = {'
        Add-Line $trials 9 "building_type = $building"
        Add-Line $trials 9 "production_method = $($transition.Candidate)"
        Add-Line $trials 8 '}'
        Add-Line $trials 7 '}'
        if ($transition.Direction -eq 'up') {
            if ($transition.Automation -and -not $transition.Transport) { Add-Line $trials 7 'state = { zw_trigger_aaap_state_workforce_low = yes }' }
            if ($transition.CheckProductivity) { Add-Line $trials 7 'cash_reserves_ratio > ffpa_auto_pm_low_cash_reserves' }
            Add-Line $trials 7 'state = {'
            foreach ($line in (Get-PriceLines -Inputs $transition.Inputs -Outputs $transition.Outputs -Indent 8 -CheckOutput $transition.CheckProductivity -InputThreshold 'ffpa_auto_pm_hold_input_price')) { [void]$trials.Append($line + "`r`n") }
            Add-Line $trials 7 '}'
        }
        else {
            Add-Line $trials 7 'OR = {'
            if ($transition.Automation) {
                Add-Line $trials 8 'state = { NOT = { zw_trigger_aaap_state_workforce_low = yes } }'
            }
            else {
                Add-Line $trials 8 'AND = { weekly_profit <= 0 is_subsidized = no }'
                Add-Line $trials 8 'cash_reserves_ratio <= ffpa_auto_pm_low_cash_reserves'
            }
            foreach ($good in $transition.PressureInputs) { Add-Line $trials 8 "state = { sg:${good} = { state_goods_pricier > ffpa_auto_pm_downgrade_input_price } }" }
            Add-Line $trials 7 '}'
            foreach ($good in $transition.ReducedOutputs) { Add-Line $trials 7 "state = { sg:${good} = { state_goods_pricier < ffpa_auto_pm_downgrade_output_ceiling } }" }
        }
        Add-Line $trials 6 '}'
        Add-Line $trials 6 "state = { change_variable = { name = $pendingMonthsVar add = 1 } }"
        Add-Line $trials 6 'if = {'
        Add-Line $trials 7 "limit = { state = { var:$pendingMonthsVar >= ffpa_auto_pm_candidate_months } }"
        if ($transition.CheckProductivity) {
            Add-Line $trials 7 'ffpa_capture_auto_pm_productivity_band = {'
            Add-Line $trials 8 "BASELINE_VAR = $baselineVar"
            Add-Line $trials 7 '}'
        }
        Add-Line $trials 7 'state = {'
        Add-Line $trials 8 "set_variable = { name = $trialMonthsVar value = 0 }"
        if ($transition.CheckProductivity) {
            Add-Line $trials 8 "set_variable = { name = $successVar value = 0 }"
            Add-Line $trials 8 "set_variable = { name = $failureVar value = 0 }"
        }
        Add-Line $trials 8 "set_variable = $trialVar"
        Add-Line $trials 8 "set_variable = ffpa_trial_$($transition.VarKey)"
        Add-Line $trials 8 "remove_variable = $pendingVar"
        Add-Line $trials 8 "remove_variable = $pendingMonthsVar"
        Add-Line $trials 8 "remove_variable = ffpa_pending_$($transition.VarKey)"
        Add-Line $trials 7 '}'
        Add-Line $trials 7 ('debug_log = "FFPA_PM|TRIAL_START|{0}|{1}|{2}|{3}|{4}->{5}"' -f $transition.Direction.ToUpperInvariant(), $transition.VarKey, $building, $transition.Pmg, $transition.Previous, $transition.Candidate)
        Add-Line $trials 7 'state = {'
        Add-Line $trials 8 'activate_production_method = {'
        Add-Line $trials 9 "building_type = $building"
        Add-Line $trials 9 "production_method = $($transition.Candidate)"
        Add-Line $trials 8 '}'
        Add-Line $trials 7 '}'
        Add-Line $trials 6 '}'
        Add-Line $trials 5 '}'
        Add-Line $trials 5 'else = {'
        Add-Line $trials 6 "state = { remove_variable = ffpa_pending_$($transition.VarKey) }"
        Add-Line $trials 6 ('debug_log = "FFPA_PM|CANDIDATE_CANCEL|{0}|{1}|{2}|conditions no longer hold"' -f $transition.VarKey, $building, $transition.Pmg)
        Add-Line $trials 6 "$clearEffect = yes"
        Add-Line $trials 5 '}'
        Add-Line $trials 4 '}'
    }
    Add-Line $trials 3 '}'

    Add-Line $trials 3 'if = {'
    Add-Line $trials 4 "limit = { state = { has_variable = $trialVar } }"
    Add-Line $trials 4 "state = { change_variable = { name = $trialMonthsVar add = 1 } }"
    foreach ($transition in $buildingTransitions) {
        $groupCooldownVar = "ffpa_ap_${workflowKey}_$($transition.GroupKey)_cooldown"
        Add-Line $trials 4 'if = {'
        Add-Line $trials 5 "limit = { state = { has_variable = ffpa_trial_$($transition.VarKey) } }"
        Add-Line $trials 5 'if = {'
        Add-Line $trials 6 "limit = { NOT = { has_active_production_method = $($transition.Candidate) } }"
        Add-Line $trials 6 "state = { remove_variable = ffpa_trial_$($transition.VarKey) }"
        Add-Line $trials 6 ('debug_log = "FFPA_PM|EXTERNAL_CANCEL|{0}|{1}|{2}|candidate PM no longer active; 12 month manual lock"' -f $transition.VarKey, $building, $transition.Pmg)
        Add-Line $trials 6 "$clearEffect = yes"
        Add-Line $trials 6 "state = { set_variable = { name = $manualLockVar value = 1 months = ffpa_auto_pm_manual_lock_months } }"
        Add-Line $trials 5 '}'
        if ($transition.Inputs.Count -gt 0) {
            Add-Line $trials 5 'else_if = {'
            Add-Line $trials 6 'limit = {'
            Add-Line $trials 7 'state = { OR = {'
            foreach ($good in $transition.Inputs) { Add-Line $trials 8 "sg:${good} = { state_goods_pricier > ffpa_auto_pm_emergency_input_price }" }
            Add-Line $trials 7 '} }'
            Add-Line $trials 6 '}'
            Add-Line $trials 6 "state = { activate_production_method = { building_type = $building production_method = $($transition.Previous) } }"
            Add-Line $trials 6 "state = { remove_variable = ffpa_trial_$($transition.VarKey) }"
            Add-Line $trials 6 ('debug_log = "FFPA_PM|EMERGENCY_ROLLBACK|{0}|{1}|{2}|{3}->{4}"' -f $transition.VarKey, $building, $transition.Pmg, $transition.Candidate, $transition.Previous)
            Add-Line $trials 6 "$clearEffect = yes"
            Add-Line $trials 6 "state = { set_variable = { name = $groupCooldownVar value = 1 months = ffpa_auto_pm_failure_cooldown_months } }"
            Add-Line $trials 5 '}'
        }
        if ($transition.CheckProductivity) {
            # Old saves may contain live trials created before the counters were
            # initialized.  Preserve the active PM and captured baseline, then
            # give the repaired trial a fresh observation window.
            Add-Line $trials 5 'else_if = {'
            Add-Line $trials 6 'limit = {'
            Add-Line $trials 7 'state = {'
            Add-Line $trials 8 "NOT = { has_variable = $successVar }"
            Add-Line $trials 8 "NOT = { has_variable = $failureVar }"
            Add-Line $trials 7 '}'
            Add-Line $trials 6 '}'
            Add-Line $trials 6 'state = {'
            Add-Line $trials 7 "set_variable = { name = $successVar value = 0 }"
            Add-Line $trials 7 "set_variable = { name = $failureVar value = 0 }"
            Add-Line $trials 7 "set_variable = { name = $trialMonthsVar value = 0 }"
            Add-Line $trials 6 '}'
            Add-Line $trials 6 ('debug_log = "FFPA_PM|COUNTER_REPAIR|{0}|{1}|{2}|{3}|observation restarted"' -f $transition.VarKey, $building, $transition.Pmg, $transition.Direction.ToUpperInvariant())
            Add-Line $trials 5 '}'
        }
        Add-Line $trials 5 'else_if = {'
        Add-Line $trials 6 "limit = { state = { var:$trialMonthsVar >= $($transition.Observation) } }"
        if ($transition.CheckProductivity) {
            Add-Line $trials 6 'if = {'
            Add-Line $trials 7 'limit = {'
            Add-Line $trials 8 'AND = {'
            Add-Line $trials 9 'ffpa_auto_pm_productivity_improved = {'
            Add-Line $trials 10 "BASELINE_VAR = $baselineVar"
            Add-Line $trials 9 '}'
            Add-Line $trials 9 'OR = { weekly_profit > 0 is_subsidized = yes }'
            Add-Line $trials 8 '}'
            Add-Line $trials 7 '}'
            Add-AutoPmCounterIncrement -Builder $trials -Indent 7 -CounterVar $successVar -OppositeVar $failureVar
            Add-Line $trials 7 ('debug_log = "FFPA_PM|EVAL_PASS|{0}|{1}|{2}|{3}"' -f $transition.VarKey, $building, $transition.Pmg, $transition.Direction.ToUpperInvariant())
            Add-Line $trials 7 'if = {'
            Add-Line $trials 8 "limit = { state = { var:$successVar >= 2 } }"
            Add-Line $trials 8 "state = { remove_variable = ffpa_trial_$($transition.VarKey) }"
            Add-Line $trials 8 ('debug_log = "FFPA_PM|KEEP|{0}|{1}|{2}|{3}|{4}"' -f $transition.VarKey, $building, $transition.Pmg, $transition.Direction.ToUpperInvariant(), $transition.Candidate)
            Add-Line $trials 8 "$clearEffect = yes"
            Add-AutoPmSuccessState -Builder $trials -Indent 8 -Transition $transition -WorkflowKey $workflowKey
            Add-Line $trials 7 '}'
            Add-Line $trials 6 '}'
            Add-Line $trials 6 'else = {'
            Add-AutoPmCounterIncrement -Builder $trials -Indent 7 -CounterVar $failureVar -OppositeVar $successVar
            Add-Line $trials 7 'if = {'
            Add-Line $trials 8 'limit = {'
            Add-Line $trials 9 'NOT = {'
            Add-Line $trials 10 'ffpa_auto_pm_productivity_improved = {'
            Add-Line $trials 11 "BASELINE_VAR = $baselineVar"
            Add-Line $trials 10 '}'
            Add-Line $trials 9 '}'
            Add-Line $trials 8 '}'
            Add-Line $trials 8 ('debug_log = "FFPA_PM|EVAL_FAIL|{0}|{1}|{2}|{3}|EARNINGS"' -f $transition.VarKey, $building, $transition.Pmg, $transition.Direction.ToUpperInvariant())
            Add-Line $trials 7 '}'
            Add-Line $trials 7 'else = {'
            Add-Line $trials 8 ('debug_log = "FFPA_PM|EVAL_FAIL|{0}|{1}|{2}|{3}|WEEKLY_PROFIT"' -f $transition.VarKey, $building, $transition.Pmg, $transition.Direction.ToUpperInvariant())
            Add-Line $trials 7 '}'
            Add-Line $trials 7 'if = {'
            Add-Line $trials 8 "limit = { state = { var:$failureVar >= 2 } }"
            Add-Line $trials 8 "state = { activate_production_method = { building_type = $building production_method = $($transition.Previous) } }"
            Add-Line $trials 8 "state = { remove_variable = ffpa_trial_$($transition.VarKey) }"
            Add-Line $trials 8 ('debug_log = "FFPA_PM|ROLLBACK|{0}|{1}|{2}|{3}->{4}"' -f $transition.VarKey, $building, $transition.Pmg, $transition.Candidate, $transition.Previous)
            Add-Line $trials 8 "$clearEffect = yes"
            Add-Line $trials 8 "state = { set_variable = { name = $groupCooldownVar value = 1 months = ffpa_auto_pm_failure_cooldown_months } }"
            Add-Line $trials 7 '}'
            Add-Line $trials 6 '}'
        }
        else {
            Add-Line $trials 6 "state = { remove_variable = ffpa_trial_$($transition.VarKey) }"
            Add-Line $trials 6 ('debug_log = "FFPA_PM|SUCCESS_NO_PRODUCTIVITY|{0}|{1}|{2}"' -f $transition.VarKey, $building, $transition.Candidate)
            Add-Line $trials 6 "$clearEffect = yes"
            Add-AutoPmSuccessState -Builder $trials -Indent 6 -Transition $transition -WorkflowKey $workflowKey
        }
        Add-Line $trials 5 '}'
        Add-Line $trials 4 '}'
    }
    Add-Line $trials 3 '}'
    Add-Line $trials 2 '}'
}
Add-Line $trials 1 '}'
Add-Line $trials 0 '}'

$effectsPath = Join-Path $OutputRoot 'common\scripted_effects\ffpa_generated_auto_pm_effects.txt'
$trialsPath = Join-Path $OutputRoot 'common\scripted_effects\ffpa_generated_auto_pm_trials.txt'
$triggersPath = Join-Path $OutputRoot 'common\scripted_triggers\ffpa_generated_auto_pm_triggers.txt'
[void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $triggersPath))
[System.IO.File]::WriteAllText($effectsPath, $effects.ToString(), [System.Text.UTF8Encoding]::new($true))
[System.IO.File]::WriteAllText($trialsPath, $trials.ToString(), [System.Text.UTF8Encoding]::new($true))

$productivityTriggers = [System.Text.StringBuilder]::new()
Add-Line $productivityTriggers 0 '# Generated production-manager compatibility and productivity triggers.'

# Eligibility triggers let ordered selections retain the upstream one/three
# building budget without repeatedly spending it on an ineligible no-op.
foreach ($building in ($transitions.Building | Sort-Object -Unique)) {
    $workflowKey = $buildingWorkflowKeys[$building]
    foreach ($mode in @('production', 'automation')) {
        $modeTransitions = if ($mode -eq 'automation') {
            @($transitions | Where-Object { $_.Building -eq $building -and $_.Automation })
        }
        else {
            @($transitions | Where-Object { $_.Building -eq $building -and -not $_.Automation })
        }
        if ($modeTransitions.Count -eq 0) { continue }

        Add-Line $productivityTriggers 0 "ffpa_can_${building}_${mode}_transition = {"
        Add-Line $productivityTriggers 1 'OR = {'
        foreach ($transition in $modeTransitions) {
            $groupCooldownVar = "ffpa_ap_${workflowKey}_$($transition.GroupKey)_cooldown"
            $oscillationLockVar = "ffpa_ap_${workflowKey}_$($transition.GroupKey)_osc_lock"
            Add-Line $productivityTriggers 2 'AND = {'
            Add-Line $productivityTriggers 3 'owner = {'
            foreach ($gateVariable in ($transition.Gate -split '\+')) { Add-Line $productivityTriggers 4 "has_variable = $gateVariable" }
            Add-Line $productivityTriggers 3 '}'
            Add-Line $productivityTriggers 3 'state = {'
            Add-Line $productivityTriggers 4 "NOT = { has_variable = ffpa_ap_${workflowKey}_pending }"
            Add-Line $productivityTriggers 4 "NOT = { has_variable = ffpa_ap_${workflowKey}_trial }"
            Add-Line $productivityTriggers 4 "NOT = { has_variable = ffpa_ap_${workflowKey}_manual_lock }"
            Add-Line $productivityTriggers 4 "NOT = { has_variable = $groupCooldownVar }"
            Add-Line $productivityTriggers 4 "NOT = { has_variable = $oscillationLockVar }"
            Add-Line $productivityTriggers 3 '}'
            Add-Line $productivityTriggers 3 "has_active_production_method = $($transition.Previous)"
            Add-Line $productivityTriggers 3 'state = {'
            Add-Line $productivityTriggers 4 'can_activate_production_method = {'
            Add-Line $productivityTriggers 5 "building_type = $building"
            Add-Line $productivityTriggers 5 "production_method = $($transition.Candidate)"
            Add-Line $productivityTriggers 4 '}'
            Add-Line $productivityTriggers 3 '}'
            if ($transition.Direction -eq 'up') {
                if ($transition.Automation -and -not $transition.Transport) { Add-Line $productivityTriggers 3 'state = { zw_trigger_aaap_state_workforce_low = yes }' }
                if ($transition.CheckProductivity) { Add-Line $productivityTriggers 3 'cash_reserves_ratio > ffpa_auto_pm_low_cash_reserves' }
                Add-Line $productivityTriggers 3 'state = {'
                foreach ($line in (Get-PriceLines -Inputs $transition.Inputs -Outputs $transition.Outputs -Indent 4 -CheckOutput $transition.CheckProductivity)) { [void]$productivityTriggers.Append($line + "`r`n") }
                Add-Line $productivityTriggers 3 '}'
            }
            else {
                Add-Line $productivityTriggers 3 'OR = {'
                if ($transition.Automation) {
                    Add-Line $productivityTriggers 4 'state = { NOT = { zw_trigger_aaap_state_workforce_low = yes } }'
                }
                else {
                    Add-Line $productivityTriggers 4 'AND = { weekly_profit <= 0 is_subsidized = no }'
                    Add-Line $productivityTriggers 4 'cash_reserves_ratio <= ffpa_auto_pm_low_cash_reserves'
                }
                foreach ($good in $transition.PressureInputs) { Add-Line $productivityTriggers 4 "state = { sg:${good} = { state_goods_pricier > ffpa_auto_pm_downgrade_input_price } }" }
                Add-Line $productivityTriggers 3 '}'
                foreach ($good in $transition.ReducedOutputs) { Add-Line $productivityTriggers 3 "state = { sg:${good} = { state_goods_pricier < ffpa_auto_pm_downgrade_output_ceiling } }" }
            }
            Add-Line $productivityTriggers 2 '}'
        }
        Add-Line $productivityTriggers 1 '}'
        Add-Line $productivityTriggers 0 '}'
        Add-Line $productivityTriggers 0
    }
}

# The upstream production manager only knows its original PM lists. For an
# adapted building type the generated manager covers the complete relevant PM
# chains, so guarded instances stay under one authority in both directions.
# The guard is inserted into the upstream ordered selection; its replacement
# then applies the same one/three-instance budget to our eligible instances.
foreach ($building in ($productionBuildings | Sort-Object)) {
    if ($newBuildingCategories.Contains($building)) { continue }
    if (-not $autoPmEffects[$building]) { continue }

    $workflowKey = $buildingWorkflowKeys[$building]
    $managedMethods = @($transitions |
        Where-Object { $_.Building -eq $building -and -not $_.Automation } |
        Select-Object -ExpandProperty Candidate -Unique)
    if ($managedMethods.Count -eq 0) { continue }

    Add-Line $productivityTriggers 0 "ffpa_auto_pm_upstream_guard_${workflowKey} = {"
    Add-Line $productivityTriggers 1 'OR = {'
    Add-Line $productivityTriggers 2 'state = {'
    Add-Line $productivityTriggers 3 'OR = {'
    Add-Line $productivityTriggers 4 "has_variable = ffpa_ap_${workflowKey}_pending"
    Add-Line $productivityTriggers 4 "has_variable = ffpa_ap_${workflowKey}_trial"
    Add-Line $productivityTriggers 3 '}'
    Add-Line $productivityTriggers 2 '}'
    foreach ($method in $managedMethods) {
        Add-Line $productivityTriggers 2 "has_active_production_method = $method"
    }
    Add-Line $productivityTriggers 1 '}'
    Add-Line $productivityTriggers 0 '}'
    Add-Line $productivityTriggers 0
}

# The upstream automation mod selects at most one building from a state and then
# applies a decision tree that only knows its bundled methods.  Excluding guarded
# instances in the ordered selection preserves that one-building budget for an
# unguarded instance and prevents a new Tech & Res automation/transport method
# from being replaced by an older method on the next scan.
foreach ($guardMode in @(
    [pscustomobject]@{ Name = 'automation'; Transport = $false },
    [pscustomobject]@{ Name = 'transport'; Transport = $true }
)) {
    $modeTransitions = @($transitions | Where-Object {
        $_.Automation -and $_.Transport -eq $guardMode.Transport
    })
    Add-Line $productivityTriggers 0 "ffpa_auto_pm_upstream_$($guardMode.Name)_guard = {"
    Add-Line $productivityTriggers 1 'OR = {'
    foreach ($building in ($modeTransitions.Building | Sort-Object -Unique)) {
        $workflowKey = $buildingWorkflowKeys[$building]
        $managedMethods = @($modeTransitions |
            Where-Object Building -eq $building |
            Select-Object -ExpandProperty Candidate -Unique)
        Add-Line $productivityTriggers 2 'AND = {'
        Add-Line $productivityTriggers 3 "is_building_type = $building"
        Add-Line $productivityTriggers 3 'OR = {'
        Add-Line $productivityTriggers 4 'state = {'
        Add-Line $productivityTriggers 5 'OR = {'
        Add-Line $productivityTriggers 6 "has_variable = ffpa_ap_${workflowKey}_pending"
        Add-Line $productivityTriggers 6 "has_variable = ffpa_ap_${workflowKey}_trial"
        Add-Line $productivityTriggers 5 '}'
        Add-Line $productivityTriggers 4 '}'
        foreach ($method in $managedMethods) {
            Add-Line $productivityTriggers 4 "has_active_production_method = $method"
        }
        Add-Line $productivityTriggers 3 '}'
        Add-Line $productivityTriggers 2 '}'
    }
    Add-Line $productivityTriggers 1 '}'
    Add-Line $productivityTriggers 0 '}'
    Add-Line $productivityTriggers 0
}

Add-Line $productivityTriggers 0 'ffpa_auto_pm_productivity_improved = {'
Add-Line $productivityTriggers 1 'OR = {'
for ($bandIndex = 0; $bandIndex -lt $capturedProductivityBandCount; $bandIndex++) {
    $requiredThresholdValue = if ($bandIndex -eq 0) { [decimal]0 } else { $productivityThresholds[$bandIndex - 1] }
    $requiredThreshold = $requiredThresholdValue.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
    Add-Line $productivityTriggers 2 'AND = {'
    Add-Line $productivityTriggers 3 "state = { var:`$BASELINE_VAR`$ = $bandIndex }"
    Add-Line $productivityTriggers 3 "earnings >= $requiredThreshold"
    Add-Line $productivityTriggers 2 '}'
}
Add-Line $productivityTriggers 1 '}'
Add-Line $productivityTriggers 0 '}'
$economicTransitionCount = @($transitions | Where-Object CheckProductivity).Count
$trialText = $trials.ToString()
$triggerText = $productivityTriggers.ToString()
$counterRepairCount = [regex]::Matches($trialText, 'FFPA_PM\|COUNTER_REPAIR\|').Count
$successCounterZeroCount = [regex]::Matches($trialText, 'set_variable = \{ name = ffpa_ap_[A-Za-z0-9_]+_success_checks value = 0 \}').Count
$failureCounterZeroCount = [regex]::Matches($trialText, 'set_variable = \{ name = ffpa_ap_[A-Za-z0-9_]+_failure_checks value = 0 \}').Count
$successCounterOneCount = [regex]::Matches($trialText, 'set_variable = \{ name = ffpa_ap_[A-Za-z0-9_]+_success_checks value = 1 \}').Count
$failureCounterOneCount = [regex]::Matches($trialText, 'set_variable = \{ name = ffpa_ap_[A-Za-z0-9_]+_failure_checks value = 1 \}').Count
$capturedBandAssignmentCount = [regex]::Matches($trialText, 'set_variable = \{ name = \$BASELINE_VAR\$ value = [0-9]+ \}').Count
$acceptanceBandBranchCount = [regex]::Matches($triggerText, 'state = \{ var:\$BASELINE_VAR\$ = [0-9]+ \}').Count
if ($counterRepairCount -ne $economicTransitionCount) { throw "Expected $economicTransitionCount counter-repair branches, got $counterRepairCount" }
if ($successCounterZeroCount -ne ($economicTransitionCount * 2)) { throw "Expected $($economicTransitionCount * 2) success-counter zero initializers, got $successCounterZeroCount" }
if ($failureCounterZeroCount -ne ($economicTransitionCount * 2)) { throw "Expected $($economicTransitionCount * 2) failure-counter zero initializers, got $failureCounterZeroCount" }
if ($successCounterOneCount -ne $economicTransitionCount) { throw "Expected $economicTransitionCount self-initializing success increments, got $successCounterOneCount" }
if ($failureCounterOneCount -ne $economicTransitionCount) { throw "Expected $economicTransitionCount self-initializing failure increments, got $failureCounterOneCount" }
if ($capturedBandAssignmentCount -ne $capturedProductivityBandCount) { throw "Expected $capturedProductivityBandCount captured earnings bands, got $capturedBandAssignmentCount" }
if ($acceptanceBandBranchCount -ne $capturedProductivityBandCount) { throw "Expected $capturedProductivityBandCount earnings acceptance bands, got $acceptanceBandBranchCount" }
[System.IO.File]::WriteAllText($triggersPath, $productivityTriggers.ToString(), [System.Text.UTF8Encoding]::new($true))

$coverage = [System.Text.StringBuilder]::new()
$coveredAutomationBuildings = @($transitions | Where-Object Automation | Select-Object -ExpandProperty Building -Unique)
$coveredAutomationPmgs = @($transitions | Where-Object Automation | Select-Object -ExpandProperty Pmg -Unique)
$uncoveredAutomationBuildings = @($automationBuildings | Where-Object { $_ -notin $coveredAutomationBuildings } | Sort-Object)
$uncoveredAutomationPmgs = @($activeAutomationPmgs | Where-Object { $_ -notin $coveredAutomationPmgs } | Sort-Object)
[void]$coverage.AppendLine('# Generated Tech & Res automatic-production coverage')
[void]$coverage.AppendLine()
[void]$coverage.AppendLine("- Generated transitions: $($transitions.Count)")
[void]$coverage.AppendLine("- Preserved legacy forward transitions: $(@($transitions | Where-Object Legacy).Count)")
[void]$coverage.AppendLine("- Upward transitions: $(@($transitions | Where-Object Direction -eq 'up').Count)")
[void]$coverage.AppendLine("- Downward transitions: $(@($transitions | Where-Object Direction -eq 'down').Count)")
[void]$coverage.AppendLine("- Production buildings: $($productionBuildings.Count)")
[void]$coverage.AppendLine("- Automation buildings covered: $($coveredAutomationBuildings.Count)/$($automationBuildings.Count)")
[void]$coverage.AppendLine("- Active automation PMGs covered: $($coveredAutomationPmgs.Count)/$($activeAutomationPmgs.Count)")
[void]$coverage.AppendLine("- Upstream automation building/PM pairs classified as automation or transport: $($upstreamAutomationBuildingPmPairs.Count - $missingUpstreamAutomationPairs.Count)/$($upstreamAutomationBuildingPmPairs.Count)")
[void]$coverage.AppendLine("- Explosives factory ordinary production transitions: $($explosivesProductionTransitions.Count) (up $(@($explosivesProductionTransitions | Where-Object Direction -eq 'up').Count), down $(@($explosivesProductionTransitions | Where-Object Direction -eq 'down').Count))")
[void]$coverage.AppendLine("- Earnings bands captured and accepted: $capturedProductivityBandCount/$acceptanceBandBranchCount (2% geometric bands; acceptance uses the captured band's lower boundary)")
[void]$coverage.AppendLine("- Uncovered automation buildings: $(if ($uncoveredAutomationBuildings.Count) { $uncoveredAutomationBuildings -join ', ' } else { 'none' })")
[void]$coverage.AppendLine("- Uncovered active automation PMGs: $(if ($uncoveredAutomationPmgs.Count) { $uncoveredAutomationPmgs -join ', ' } else { 'none' })")
[void]$coverage.AppendLine('- Intentionally excluded upstream orphan: `pmg_data_optimization_heavy_industry_software` (no effective building attachment).')
[void]$coverage.AppendLine('- Intentionally excluded upstream orphan: `pmg_train_automation_building_hydroponic` (its referenced attachment target does not exist).')
[void]$coverage.AppendLine()
[void]$coverage.AppendLine('| Building | PMG | Previous | Candidate | Direction | Kind | Gate |')
[void]$coverage.AppendLine('|---|---|---|---|---|---|---|')
foreach ($transition in $transitions | Sort-Object Building,Pmg,Previous,Candidate) {
    $kind = if ($transition.Automation) { if ($transition.Transport) { 'transport' } else { 'automation' } } else { 'production' }
    [void]$coverage.AppendLine("| $($transition.Building) | $($transition.Pmg) | $($transition.Previous) | $($transition.Candidate) | $($transition.Direction) | $kind | $($transition.Gate) |")
}
$coveragePath = Join-Path $OutputRoot 'TECHRES_AUTO_PM_COVERAGE.md'
[System.IO.File]::WriteAllText($coveragePath, $coverage.ToString(), [System.Text.UTF8Encoding]::new($false))

Write-Output "Generated $($transitions.Count) transitions"
Write-Output "Production buildings: $($productionBuildings.Count)"
Write-Output "Automation buildings: $($automationBuildings.Count)"
Write-Output "Active automation PMGs: $($activeAutomationPmgs.Count)"
Write-Output $effectsPath
Write-Output $trialsPath
Write-Output $triggersPath
Write-Output $coveragePath
