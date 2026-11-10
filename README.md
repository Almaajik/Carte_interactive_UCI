# Carte des courses UCI

## Site

Le site est statique et peut être publié avec GitHub Pages. Les classements sont servis depuis `data/results/`. Les courses en équipe utilisent Supabase comme backend commun.

## Comptes et collection

Les comptes utilisent Supabase Auth avec email et mot de passe. La progression est sauvegardée dans la table `public.user_collections`; la sécurité au niveau des lignes (RLS) garantit qu’un utilisateur ne peut lire ou modifier que sa propre collection. Le tableau de bord Supabase permet de consulter la table avec **Database → Table Editor**.

1. Crée un projet Supabase.
2. Dans **SQL Editor**, exécute `supabase/migrations/202610290001_user_collections.sql`, puis `supabase/migrations/202611100001_user_collections_drops.sql` pour initialiser la monnaie en drops.
3. Exécute `supabase/migrations/202610290002_profiles.sql` pour activer les noms d’utilisateur uniques (insensibles à la casse), puis `supabase/migrations/202611100002_races_and_rewards.sql`, `supabase/migrations/202611100003_race_course_profiles.sql` et `supabase/migrations/202611100004_race_breakaways.sql` pour créer les courses, leurs profils, le calcul pondéré des équipes et la simulation d’échappées.
4. Active la confirmation email et définis une longueur minimale de mot de passe de 12 caractères dans les réglages Auth.
5. Dans les URL de redirection autorisées, ajoute `https://almaajik.github.io/Carte_interactive_UCI/collection.html`, `https://almaajik.github.io/Carte_interactive_UCI/profile.html`, `http://localhost:8000/collection.html` et `http://localhost:8000/profile.html` pour le développement local.
6. Copie l’URL du projet et sa clé `publishable` dans `supabase-config.js`.
7. Publie les changements sur GitHub Pages.

La clé publishable est destinée au navigateur. Les politiques RLS protègent les données. Ne mets jamais une clé `secret` ou `service_role` dans ce dépôt ou dans le code du site.

À la première connexion, la collection invitée est fusionnée avec le compte. La déconnexion retire les données de compte du stockage local de l’appareil. Pour les comptes déjà créés avec l’ancien serveur Flask local, les utilisateurs et mots de passe ne sont pas migrés; les collections invitées restent importables lors de la première connexion Supabase.

Le bouton portant le nom d’utilisateur ouvre `profile.html`, où il est possible de modifier le nom unique et le mot de passe.

La récupération de mot de passe est gérée par Supabase Auth et redirige vers `profile.html`; configure cette URL publiée dans **Authentication → URL Configuration**.

### Courses en équipe

L’onglet **Courses** tire une course au sort dans le calendrier chaque jour. Supabase conserve le choix quotidien pour que tous les joueurs participent à la même course. Les inscriptions sont ouvertes de 0 h à 19 h 55 et ferment avant le départ de 20 h, selon le fuseau `Europe/Paris`. Une équipe contient cinq cartes distinctes; son score est recalculé côté Supabase en pondérant les compétences montagne, rouleur et sprint selon le profil du parcours. Les profils 2026 sont des estimations heuristiques, pas des relevés GPS : la part montagne correspond à la distance estimée au-dessus de 3 % de pente, et le sprint ne compte que si l’arrivée est jugée favorable. La chance qu’une échappée aille au bout est estimée à 10 % sur un parcours plat, 30 % vallonné et 50 % montagneux. Si elle gagne, le groupe est tiré parmi les coureurs des équipes inscrites, classé selon le profil et les notes des coureurs; les trois premiers donnent respectivement 30, 20 et 10 points bonus à leurs équipes. Après la course, la page affiche un schéma de profil, le résultat de l’échappée et les trois meilleurs joueurs et coureurs à chaque point clé. Chaque participant reçoit 20 drops; les places 1 à 3 gagnent respectivement 3, 2 et 1 booster. En cas d’égalité, les boosters des places concernées sont partagés; les boosters indivisibles restants vont aux comptes dans l’ordre déterministe de leur identifiant. Les récompenses se réclament dans la boîte de réception et sont ajoutées une seule fois à la collection.

La date de l’édition d’origine est indiquée à titre informatif; l’inscription porte sur la course quotidienne et non sur sa date passée du calendrier. Lorsqu’une nouvelle saison est ajoutée, exécute `python race_profiles.py` pour régénérer les profils estimés, puis prépare une migration Supabase pour synchroniser ces profils et les notes des coureurs. En mode invité, le choix quotidien est seulement local et les inscriptions restent désactivées. Les résultats des courses terminées sont réglés par Supabase lors de la prochaine consultation du jeu après 20 h; les récompenses apparaissent alors dans la boîte de réception.

### Réinitialiser une collection

Dans `supabase/scripts/reset_user_collection.sql`, remplace `REMPLACER_PAR_EMAIL` par l’adresse du compte à réinitialiser, puis exécute le fichier dans **SQL Editor**. Cela remet à zéro les cartes, drops et boosters, sans supprimer le compte ni son nom de profil. L’action est irréversible.

## Tests locaux

Ouvre `index.html` avec un serveur statique, ou exécute :

```powershell
python -m http.server 8000
```

Sans configuration Supabase, la carte, les classements et les boosters restent utilisables en mode invité. Le calendrier des courses est consultable en lecture seule; participer et récupérer des récompenses nécessite un compte Supabase et la migration des courses.

Les tests Python des scripts de calendrier et de résultats se lancent avec :

```powershell
python -m unittest discover -s tests -v
```