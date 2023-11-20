#!/bin/bash

# URL du fichier à télécharger
url="https://example.com/chemin/vers/le/fichier.zip"

# Emplacement de destination pour le téléchargement
destination="/chemin/local/vers/le/fichier.zip"

# Utilisation de curl pour télécharger le fichier
curl -o "$destination" "$url"

# Vérification de la réussite du téléchargement
if [ $? -eq 0 ]; then
    echo "Téléchargement réussi vers $destination"
else
    echo "Échec du téléchargement. Veuillez vérifier l'URL et votre connexion Internet."
fi
