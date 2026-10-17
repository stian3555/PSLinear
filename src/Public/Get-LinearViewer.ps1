function Get-LinearViewer {
    <#
    .SYNOPSIS
        Gets the user the current credential belongs to.

    .DESCRIPTION
        Returns the authenticated Linear user and the name of their organization.
        Useful for checking which account a credential belongs to.

    .EXAMPLE
        Get-LinearViewer

        Shows the authenticated user.

    .INPUTS
        None.

    .OUTPUTS
        PSLinear.User

    .LINK
        Connect-Linear
    #>
    [CmdletBinding()]
    [OutputType('PSLinear.User')]
    param()

    $data = Invoke-LinearRequest -Query (Get-LinearGraphQLDocument -Name 'Viewer')
    $viewer = ConvertTo-LinearUser -InputObject (Get-LinearNestedValue -InputObject $data -Name 'viewer') `
        -Organization (Get-LinearNestedValue -InputObject $data -Name 'organization')
    # PSLinear.Viewer selects a view that shows the organization; it is still a PSLinear.User.
    if ($null -ne $viewer) { $viewer.PSObject.TypeNames.Insert(0, 'PSLinear.Viewer') }
    $viewer
}
