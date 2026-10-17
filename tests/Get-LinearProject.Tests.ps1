BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Get-PSLinearTestModulePath) -Force
}

Describe 'Get-LinearProject' {
    BeforeEach {
        InModuleScope PSLinear {
            Clear-LinearCache
            $script:LinearContext = New-LinearContext -Token (ConvertTo-LinearSecureString -Value 'lin_api_test') -AuthScheme 'ApiKey'
        }
        Mock -ModuleName PSLinear Send-LinearHttpRequest {
            $request = Get-RequestBody -Body $Body
            $lookup = Get-LinearTestLookupResponse -Request $request
            if ($lookup) { return $lookup }
            Get-LinearTestProjectResponse -Request $request
        }
    }

    It 'lists the projects as typed objects, sorted by name' {
        $projects = @(Get-LinearProject)
        $projects.Name | Should -Be @('Mobile App', 'Website')
        $website = $projects[1]
        $website.PSObject.TypeNames | Should -Contain 'PSLinear.Project'
        $website.Status | Should -Be 'In Progress'
        $website.Lead | Should -Be 'Grace Hopper'
        $website.LeadId | Should -Be 'user-grace'
        $website.Progress | Should -Be 0.5
        $website.TargetDate | Should -Be '2026-12-01'
        $projects[0].Lead | Should -BeNullOrEmpty
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
            (Get-RequestBody $Body).variables.includeArchived -eq $false
        }
    }

    It 'flattens status, health, priority, teams and labels, keeping the ids' {
        $website = Get-LinearProject -Name Website
        $mobile = Get-LinearProject -Name 'Mobile App'
        $website.StatusType | Should -Be 'started'
        $website.StatusId | Should -Be 'pstatus-progress'
        $website.Health | Should -Be 'OnTrack'
        $website.Priority | Should -Be 2
        $website.PriorityLabel | Should -Be 'High'
        $website.Teams | Should -Be @('ENG')
        $website.TeamIds | Should -Be @('team-eng')
        $website.Labels | Should -Be @('Customer')
        $website.LabelIds | Should -Be @('plabel-customer')
        $website.Description | Should -Be 'The public site'
        $mobile.Teams | Should -Be @('ENG', 'OPS')
        $mobile.Labels | Should -BeNullOrEmpty
        $mobile.Health | Should -BeNullOrEmpty
    }

    It 'leaves the detail fields empty in lists' {
        $website = Get-LinearProject -Name Website
        $website.Content | Should -BeNullOrEmpty
        $website.Members | Should -BeNullOrEmpty
        $website.Initiatives | Should -BeNullOrEmpty
    }

    It 'includes archived projects with -IncludeArchived' {
        $legacy = Get-LinearProject -IncludeArchived | Where-Object Name -EQ 'Legacy'
        $legacy.ArchivedAt | Should -Not -BeNullOrEmpty
    }

    It 'filters by name with wildcards and reports names that match nothing' {
        (Get-LinearProject -Name 'web*').Id | Should -Be 'project-web'
        $projects = @(Get-LinearProject -Name 'Website', 'Intranet' -ErrorAction SilentlyContinue -ErrorVariable projectErrors)
        $projects.Id | Should -Be @('project-web')
        $projectErrors.Count | Should -Be 1
        $projectErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectNotFound*'
    }

    It 'accepts names from the pipeline and fetches the projects once' {
        @('Website', 'Mobile App' | Get-LinearProject).Id | Should -Be @('project-web', 'project-mobile')
        Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly
    }

    Context '-Team' {
        It 'returns only the projects of a team' {
            @(Get-LinearProject -Team OPS).Name | Should -Be @('Mobile App')
            @(Get-LinearProject -Team ENG).Name | Should -Be @('Mobile App', 'Website')
        }

        It 'stops with the valid team keys for an unknown team' {
            { Get-LinearProject -Team NOPE } | Should -Throw -ErrorId 'PSLinear.TeamNotFound*' -ExpectedMessage '*Available team keys: ENG, OPS.*'
        }
    }

    Context '-Status' {
        It 'matches a status by name, case-insensitively' {
            @(Get-LinearProject -Status 'planned').Name | Should -Be @('Mobile App')
            @(Get-LinearProject -Status 'in progress').Name | Should -Be @('Website')
        }

        It 'matches every status of a type' {
            @(Get-LinearProject -Status started).Name | Should -Be @('Website')
            @(Get-LinearProject -Status started, Planned).Name | Should -Be @('Mobile App', 'Website')
        }

        It 'combines with -Name and -Team' {
            @(Get-LinearProject -Name '*' -Team ENG -Status planned).Name | Should -Be @('Mobile App')
            @(Get-LinearProject -Team OPS -Status started) | Should -BeNullOrEmpty
        }

        It 'stops with the valid statuses and types for an unknown status' {
            { Get-LinearProject -Status Shipped } | Should -Throw -ErrorId 'PSLinear.ProjectStatusNotFound*' -ExpectedMessage (
                "Project status 'Shipped' was not found. Valid statuses: Backlog, Planned, In Progress, Beta testing, Paused, Completed, Canceled; " +
                'status types: backlog, planned, started, paused, completed, canceled.')
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 0 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'ListProjects' }
        }
    }

    Context '-Id and piped projects' {
        It 'gets the full project by id, slug id or URL' {
            foreach ($value in 'project-web', 'a1b2c3d4e5f6', 'https://linear.app/acme/project/website-a1b2c3d4e5f6/overview') {
                $project = Get-LinearProject -Id $value
                $project.Id | Should -Be 'project-web'
                $project.Content | Should -Be "# Website`nRelaunch plan"
                $project.Members | Should -Be @('Ada Lovelace', 'Grace Hopper')
                $project.MemberIds | Should -Be @('user-ada', 'user-grace')
                $project.Initiatives | Should -Be @('Growth')
                $project.Teams | Should -Be @('ENG')
            }
            # The URL is reduced to its slug id; names are not looked up.
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 1 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetProject' -and (Get-RequestVariable $Body 'id') -eq 'project-web'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter {
                (Get-RequestOperation $Body) -eq 'GetProject' -and (Get-RequestVariable $Body 'id') -eq 'a1b2c3d4e5f6'
            }
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 3 -Exactly
        }

        It 'returns archived projects by id' {
            (Get-LinearProject -Id 'project-legacy').ArchivedAt | Should -Not -BeNullOrEmpty
        }

        It 'writes one error for a missing project and returns the others' {
            $projects = @(Get-LinearProject -Id 'project-web', 'nope', 'project-mobile' -ErrorAction SilentlyContinue -ErrorVariable projectErrors)
            $projects.Id | Should -Be @('project-web', 'project-mobile')
            $projectErrors.Count | Should -Be 1
            $projectErrors[0].FullyQualifiedErrorId | Should -BeLike 'PSLinear.ProjectNotFound*'
            $projectErrors[0].Exception.Message | Should -BeLike "Project 'nope' was not found.*"
        }

        It 'returns piped projects in full' {
            $projects = @(Get-LinearProject | Get-LinearProject)
            $projects.Name | Should -Be @('Mobile App', 'Website')
            $projects[1].Members | Should -Be @('Ada Lovelace', 'Grace Hopper')
            $projects[0].Members.Count | Should -Be 0
            Should -Invoke Send-LinearHttpRequest -ModuleName PSLinear -Times 2 -Exactly -ParameterFilter { (Get-RequestOperation $Body) -eq 'GetProject' }
        }
    }
}
