# Carte des courses UCI

## Lancer le site avec les comptes

Depuis la racine du dépôt, installe les dépendances puis démarre l’application :

```powershell
python -m pip install -r requirements.txt
python app.py
```

Ouvre `http://127.0.0.1:8000`. Utilise cette adresse plutôt que `python -m http.server` : l’API de comptes doit partager la même origine que les pages. Le port 8000 conserve aussi l’accès à l’éventuelle collection invitée du site local.

## Comptes

Les comptes utilisent un nom de 3 à 24 lettres, chiffres, tirets ou underscores, et un mot de passe de 12 à 128 caractères. Les mots de passe sont hachés; les collections sont enregistrées dans `instance/accounts.sqlite3`. Ce dossier est ignoré par Git : sauvegarde-le si tu veux conserver les comptes.

La collection invitée est fusionnée avec le compte à la première connexion. La progression du compte est ensuite synchronisée au serveur. La déconnexion retire la copie locale de cet appareil. Il n’y a pas encore de récupération de mot de passe ni de vérification email.

## Hébergement

Cette application n’est pas compatible avec un hébergement de fichiers statiques seul. Sur un serveur, installe les dépendances, monte un stockage persistant pour la base SQLite et définis `APP_ENV=production`, `SECRET_KEY` (une valeur aléatoire longue), `HOST=0.0.0.0` et `PORT` selon l’hébergeur. `DATABASE_PATH` peut définir l’emplacement de la base.

Place Waitress derrière un proxy HTTPS en production. Le mode production exige `SECRET_KEY` et marque les cookies de session `Secure`; ne désactive pas HTTPS pour contourner ce réglage.

## Tests

```powershell
python -m unittest discover -s tests -v
```