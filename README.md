# Carte des courses UCI

## Site

Le site est statique et peut être publié avec GitHub Pages. Les classements sont servis depuis `data/results/`.

## Comptes et collection

Les comptes utilisent Supabase Auth avec email et mot de passe. La progression est sauvegardée dans la table `public.user_collections`; la sécurité au niveau des lignes (RLS) garantit qu’un utilisateur ne peut lire ou modifier que sa propre collection. Le tableau de bord Supabase permet de consulter la table avec **Database → Table Editor**.

1. Crée un projet Supabase.
2. Dans **SQL Editor**, exécute `supabase/migrations/202610290001_user_collections.sql`.
3. Exécute aussi `supabase/migrations/202610290002_profiles.sql` pour activer les noms d’utilisateur uniques (insensibles à la casse).
4. Active la confirmation email et définis une longueur minimale de mot de passe de 12 caractères dans les réglages Auth.
5. Dans les URL de redirection autorisées, ajoute `https://almaajik.github.io/Carte_interactive_UCI/collection.html`, `https://almaajik.github.io/Carte_interactive_UCI/profile.html`, `http://localhost:8000/collection.html` et `http://localhost:8000/profile.html` pour le développement local.
6. Copie l’URL du projet et sa clé `publishable` dans `supabase-config.js`.
7. Publie les changements sur GitHub Pages.

La clé publishable est destinée au navigateur. Les politiques RLS protègent les données. Ne mets jamais une clé `secret` ou `service_role` dans ce dépôt ou dans le code du site.

À la première connexion, la collection invitée est fusionnée avec le compte. La déconnexion retire les données de compte du stockage local de l’appareil. Pour les comptes déjà créés avec l’ancien serveur Flask local, les utilisateurs et mots de passe ne sont pas migrés; les collections invitées restent importables lors de la première connexion Supabase.

Le bouton portant le nom d’utilisateur ouvre `profile.html`, où il est possible de modifier le nom unique et le mot de passe.

La récupération de mot de passe est gérée par Supabase Auth et redirige vers `profile.html`; configure cette URL publiée dans **Authentication → URL Configuration**.

## Tests locaux

Ouvre `index.html` avec un serveur statique, ou exécute :

```powershell
python -m http.server 8000
```

Sans configuration Supabase, la carte, les classements et les boosters restent utilisables en mode invité. Les fonctions de compte affichent un message demandant de configurer Supabase.

Les tests Python des scripts de calendrier et de résultats se lancent avec :

```powershell
python -m unittest discover -s tests -v
```