function Invoke-LinearGraphQL {
    <#
    .SYNOPSIS
        Runs any GraphQL query or mutation against the Linear API.

    .DESCRIPTION
        An escape hatch for everything the dedicated cmdlets do not cover yet. Sends the
        document with the current connection and returns the 'data' part of the response.

        You get the same authentication, error handling and rate-limit retries as the
        other cmdlets. Mutations honour -WhatIf and -Confirm, and are not sent again after a
        server error or a dropped connection (PSLinear.MutationOutcomeUnknown), because Linear
        may already have run them.

        Explore the schema in Apollo Studio:
        https://studio.apollographql.com/public/Linear-API/variant/current/home

    .PARAMETER Query
        The GraphQL document (query or mutation).

    .PARAMETER Path
        Path to a .graphql file that contains the document.

    .PARAMETER Variables
        Variables for the document, as a hashtable.

    .PARAMETER OperationName
        The operation to run when the document defines more than one.

    .EXAMPLE
        Invoke-LinearGraphQL -Query '{ viewer { id name email } }'

        Runs a simple query.

    .EXAMPLE
        $query = 'query($key: String!) { team(id: $key) { name states { nodes { id name type } } } }'
        (Invoke-LinearGraphQL -Query $query -Variables @{ key = '9cfb482a-81e3-4154-b5b9-2c805e70a02d' }).team.states.nodes

        Lists the workflow states of a team using variables.

    .EXAMPLE
        $mutation = 'mutation($id: String!, $title: String!) { issueUpdate(id: $id, input: { title: $title }) { success } }'
        Invoke-LinearGraphQL -Query $mutation -Variables @{ id = 'ENG-123'; title = 'New title' } -WhatIf

        Shows what a mutation would do without running it.

    .EXAMPLE
        Invoke-LinearGraphQL -Path ./queries/MyIssues.graphql

        Runs a document stored in a file.

    .INPUTS
        System.String

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .LINK
        https://linear.app/developers/graphql
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query', SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ParameterSetName = 'Query')]
        [ValidateNotNullOrEmpty()]
        [string] $Query,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [System.Collections.IDictionary] $Variables,

        [ValidateNotNullOrEmpty()]
        [string] $OperationName
    )

    process {
        $document = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        }
        else {
            $Query
        }

        $operation = Get-LinearOperation -Document $document -OperationName $OperationName
        if ($operation.Type -eq 'mutation') {
            $target = if ($operation.Name) { $operation.Name } else { 'anonymous mutation' }
            if (-not $PSCmdlet.ShouldProcess($target, 'Run Linear GraphQL mutation')) {
                return
            }
        }

        $requestParameters = @{ Query = $document }
        if ($Variables) { $requestParameters['Variables'] = $Variables }
        if ($OperationName) { $requestParameters['OperationName'] = $OperationName }
        Invoke-LinearRequest @requestParameters
    }
}
