# Deploying the Owlet landing page (free, on Vercel)

This app lives in the `landing/` subdirectory of the repo. Vercel's free **Hobby** tier hosts it with zero code changes. Next.js is auto-detected; the only setting that matters is the **Root Directory**.

## One-time setup (dashboard)

1. Make sure the branch is on GitHub. Either merge `landing-page` into `main`, or push it:
   ```bash
   git push -u origin landing-page
   ```
2. Go to <https://vercel.com> and sign in with GitHub (free).
3. **Add New… → Project**, then **Import** the `AKaLee-IK27/owlet` repository.
4. In the configure screen, set:
   - **Root Directory:** `landing`  ← the important one (click "Edit", pick `landing`).
   - **Framework Preset:** Next.js (auto-detected; leave as is).
   - Build/Output/Install commands: leave default (`next build` / auto / `npm install`).
5. Click **Deploy**. After ~1 minute you get a live URL like `https://owlet-xxxx.vercel.app`.

That's it. Every push to the connected branch redeploys automatically; pull requests get preview URLs.

## CLI alternative (also free)

```bash
cd landing
npx vercel            # first run logs you in + links the project; set root dir = . when prompted
npx vercel --prod     # promote to the production URL
```

## Notes

- **Static output.** The site prerenders fully static (`○ Static` in `next build`), so it's fast and cheap to serve. `vercel.json` here just pins the framework; no other config is needed.
- **Download links are placeholders.** The "Download for macOS" / footer GitHub links point at `https://github.com/AKaLee-IK27/owlet`. Swap them for a real release URL when you have one (search the components for that URL).
- **Custom domain.** Free on Vercel: Project → Settings → Domains → add your domain and follow the DNS instructions.
- **Other free hosts** (if you ever move): Cloudflare Pages or Netlify work the same way — set the base/root directory to `landing` and the framework to Next.js. GitHub Pages would additionally require `output: "export"`, `images.unoptimized`, and `basePath: "/owlet"`.
