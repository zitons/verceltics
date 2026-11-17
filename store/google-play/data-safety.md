# Google Play Data safety (Android 1.0)

Answers for Play Console → Policy → App content → Data safety. They follow how the Android app handles provider data. You are responsible for the final answers. Review them before submitting.

## What the app sends off the device

| Destination | What | Why |
|---|---|---|
| Provider APIs you connect (Vercel, Cloudflare, Netlify, Google) | Your token or API key, plus the requests needed to show your data | Only when you connect or refresh a provider. Requests go straight from the phone to that provider. Verceltics never receives them. |

The app has no ads, no Verceltics analytics, no crash reporting SDK, no in-app purchases, and no Verceltics servers.

## Data collection and security

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **No** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** |
| Do you provide a way for users to request that their data is deleted? | **Yes**: the privacy page's "Your controls" section, or by email to ad13dtu@gmail.com. Uninstalling removes everything stored on the device. |
| Account creation | **My app does not allow users to create an account** |
| Can users log in with accounts created outside the app? | **Yes → Other**: users connect accounts they already have with hosting providers, registrars and Google services, using that provider's API token or Google sign in |
| Delete data URL | https://verceltics.com/privacy#controls |

## Data types

Mark none of them: the app collects and shares no required user data types. There are
no purchases, no purchase history, no financial info, and no device or other IDs
collected by the app.

Leave everything else unchecked: location, personal info, messages, photos, audio, files, calendar, contacts, app activity, web browsing, and app info and performance. The app doesn't use an advertising ID (Advertising ID declaration: **No**).

## Judgment call: provider tokens

Provider tokens and dashboard data are sent only to the provider you choose to connect, when you ask to load it. Verceltics and its service providers never receive them, so these answers don't list them as collected. If you'd rather be conservative, you can add **App activity → Other actions** or **Personal info → Other info** as collected for app functionality. Google's guidance treats any off-device transfer as collection, so decide which reading you're comfortable with.

## Privacy policy

https://verceltics.com/privacy covers Android (updated October 9, 2026), so it matches these answers.
