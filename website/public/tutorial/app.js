const screens = [
  {
    title: "Your reading desk",
    short: "Feeds",
    summary: "Choose a source, scan its stories, and run feed-wide actions from one place.",
    image: "assets/screens/01-feed.png",
    alt: "RSSum showing the Library sidebar and a 9to5Mac article feed",
    caption: "RSS feed and subscription navigation",
    controls: [
      { x: 22.2, y: 6.5, icon: "▣", title: "Show or hide the sidebar", text: "Collapse the Library and Subscriptions column when you want more room for the feed.", tip: "Your selected source and reading position stay in place." },
      { x: 3.7, y: 26.7, icon: "☰", title: "Move around your library", text: "All combines every source. Unread isolates new items, Favorites keeps saved stories, and Today shows the latest day’s reading.", tip: "The number badges show how many unread items remain." },
      { x: 20.9, y: 52.2, icon: "≡", title: "Filter subscriptions", text: "Use the All menu above Subscriptions to show only articles, Reddit, YouTube, or podcasts.", tip: "The filter affects the sidebar list, not the articles already open." },
      { x: 13.0, y: 58.8, icon: "◉", title: "Open a subscription", text: "Select any RSS feed, subreddit, YouTube channel, or podcast to load its items in the main column.", tip: "A blue selection is RSS; Reddit sources use an orange accent." },
      { x: 29.1, y: 15.5, icon: "•", title: "Spot unread stories", text: "A small blue dot marks every story you haven’t opened yet.", tip: "The dot disappears once you read the story." },
      { x: 83.0, y: 6.5, icon: "❝", title: "Summarize the feed", text: "Create individual summaries for the visible source and open the batch summary workspace.", tip: "The ❝ symbol always means Summarize in RSSum." },
      { x: 89.6, y: 6.5, icon: "↑", title: "Refresh this source", text: "Jump back to the top and fetch the newest items for the current subscription.", tip: "This refreshes only the source you are viewing." },
      { x: 96.0, y: 6.5, icon: "✓", title: "Mark the source as read", text: "Mark every unread item in this subscription as read, then advance to the next source.", tip: "Use this after finishing a feed to keep badges and cloud read state tidy." }
    ]
  },
  {
    title: "Read without the clutter",
    short: "Reader",
    summary: "Clean up an article, summarize it, ask questions, save it, or share it.",
    image: "assets/screens/02-reader.png",
    alt: "An article open in RSSum Reader mode",
    caption: "Article Reader and its action bar",
    controls: [
      { x: 66.3, y: 7.6, icon: "▤", title: "Switch Reader mode", text: "Toggle between the cleaned Reader version and the article content supplied by its RSS feed.", tip: "Reader removes navigation, ads, and unrelated page furniture when extraction is available." },
      { x: 75.7, y: 7.6, icon: "❝", title: "Summarize the article", text: "Generate an AI summary of the current article using the Summary Source chosen in Settings.", tip: "The summary card shows its own read-aloud and copy buttons." },
      { x: 83.0, y: 7.6, icon: "W❝", title: "Summarize with your web model", text: "Send the article to ChatGPT or Gemini (whichever Web AI you chose in Settings) and bring its summary back.", tip: "The speech bubble with a quote always means “summary by the web model.” It is hidden when Web AI is already your main provider." },
      { x: 86.9, y: 7.6, icon: "☆", title: "Save to Favorites", text: "Add or remove the current article from your Favorites collection.", tip: "A filled star means the story is already saved." },
      { x: 90.8, y: 7.6, icon: "?", title: "Ask about the article", text: "Open the Ask bar, where your selected provider answers questions grounded in this story.", tip: "You can also select a passage and choose Ask AI from the text menu." },
      { x: 96.3, y: 7.6, icon: "↗", title: "Share", text: "Open the iOS share sheet for the article URL, or its title when no URL is available.", tip: "Use Share to hand the original source to another app or person." },
      { x: 95.8, y: 91.9, icon: "↑", title: "Return to the top", text: "Scroll immediately to the beginning of the article.", tip: "The floating button stays within easy reach on long reads." }
    ]
  },
  {
    title: "Ask the article",
    short: "Article Q&A",
    summary: "Turn one article into a focused conversation without losing your reading position.",
    image: "assets/screens/03-article-ask.png",
    alt: "RSSum article Ask bar with an answer below it",
    caption: "Article Ask bar and answer",
    controls: [
      { x: 30.0, y: 15.5, icon: "?", title: "Write a grounded question", text: "Type a question about claims, names, implications, or any detail in the current article.", tip: "While the field is empty, suggestion chips such as Key points, What’s new here? and Explain simply appear below it. Tap one to ask it instantly." },
      { x: 81.4, y: 15.5, icon: "W?", title: "Ask your web model", text: "Send the question and article to ChatGPT or Gemini, whichever Web AI you chose in Settings.", tip: "The two chat bubbles always mean “ask the web model.” Enter a question first to enable it." },
      { x: 85.1, y: 15.5, icon: "↑", title: "Send to your summary provider", text: "Submit the question to the Summary Source selected in Settings.", tip: "The button turns blue once the field contains text." },
      { x: 89.1, y: 15.5, icon: "×", title: "Close the Ask bar", text: "Hide the Ask bar and clear its draft and answer.", tip: "Closing it does not close the article." },
      { x: 45.0, y: 35.3, icon: "¶", title: "Read the answer", text: "The answer appears right under the Ask bar. Select any passage in it to ask a follow-up.", tip: "Answers are grounded in the article text." },
      { x: 5.9, y: 54.2, icon: "▶", title: "Listen or copy", text: "Play reads the answer with the cloud voice, the speaker uses your on-device voice, and the last icon copies the answer.", tip: "While audio plays, these turn into a single stop button." },
      { x: 89.6, y: 91.9, icon: "↑", title: "Return to the top", text: "Jump to the beginning of the article while keeping the Ask bar open.", tip: "Handy after checking a passage farther down the page." }
    ]
  },
  {
    title: "Follow a subreddit",
    short: "Reddit feed",
    summary: "Browse posts with Reddit-native ranking, then summarize or clear the source.",
    image: "assets/screens/04-reddit-feed.png",
    alt: "RSSum showing the iOSBeta subreddit feed",
    caption: "Subreddit feed and source actions",
    controls: [
      { x: 22.2, y: 6.5, icon: "▣", title: "Show or hide the sidebar", text: "Give the post list more room or bring your subscriptions back into view.", tip: "The same sidebar control is used throughout feeds." },
      { x: 13.0, y: 72.1, icon: "r/", title: "Choose a subreddit", text: "Select a Reddit subscription from the sidebar to load its ranked posts.", tip: "Unread badges are kept independently for each subreddit." },
      { x: 77.2, y: 6.5, icon: "⇅", title: "Choose Reddit sorting", text: "Change how the subreddit is ranked, such as Home, New, Hot, Rising, or Top.", tip: "Changing the sort refreshes only the active subreddit." },
      { x: 83.0, y: 6.5, icon: "❝", title: "Summarize this subreddit", text: "Choose a batch—new, hot, top day, or top week—and build summaries from its posts and comments.", tip: "The next screens explain each batch scope and the Overall Summary." },
      { x: 89.6, y: 6.5, icon: "↑", title: "Refresh posts", text: "Return to the first post and fetch the latest ranking for this subreddit.", tip: "Refresh preserves the rest of your subscription library." },
      { x: 96.0, y: 6.5, icon: "✓", title: "Mark all posts read", text: "Mark the current subreddit’s unread posts as read and advance to the next subscription.", tip: "This updates the unread badge immediately." },
      { x: 29.5, y: 30.6, icon: "•", title: "Unread dot and score", text: "A blue dot marks posts you haven’t opened; ↑ shows the post’s Reddit score, followed by the author and age.", tip: "Posts without a picture use a compact card." },
      { x: 55.0, y: 38.8, icon: "↗", title: "Open a post", text: "Select anywhere on a post card to read its body, source link, votes, and comments.", tip: "Opening a post marks that individual post as read." }
    ]
  },
  {
    title: "Read the whole discussion",
    short: "Reddit post",
    summary: "Open a post, then summarize it, save it, or share it.",
    image: "assets/screens/05c-reddit-post-header.png",
    alt: "A Reddit post open in RSSum",
    caption: "Reddit post and its actions",
    controls: [
      { x: 85.1, y: 7.6, icon: "❝", title: "Summarize the post", text: "Generate a summary of the current Reddit post with your Summary Source.", tip: "Post summary and comment summary are separate actions." },
      { x: 92.4, y: 7.6, icon: "☆", title: "Save the post", text: "Add or remove this Reddit post from Favorites.", tip: "Favorites can contain both articles and Reddit posts." },
      { x: 96.3, y: 7.6, icon: "↗", title: "Share the post", text: "Share the post URL through the standard iOS share sheet.", tip: "If the post links to an external page, that source is shared." },
      { x: 3.6, y: 43.2, icon: "❝", title: "Summarize just the post", text: "Summarize the post itself, without its comments, using your Summary Source.", tip: "Use the comment tools further down to summarize the discussion." },
      { x: 7.4, y: 43.2, icon: "W❝", title: "Summarize the post with your web model", text: "Send only the post to ChatGPT or Gemini, whichever Web AI you chose in Settings.", tip: "Hidden when Web AI is already your main provider." },
      { x: 50.0, y: 94.8, icon: "↑ ? ❝", title: "Comment shortcuts", text: "The bottom bar scrolls back to the top, opens the Ask bar, and summarizes the comments while you read deep threads.", tip: "It mirrors the main comment actions without sending you back to the header." }
    ]
  },
  {
    title: "Work with the comments",
    short: "Comments",
    summary: "Sort, summarize, question, and analyze the discussion, or reply to it.",
    image: "assets/screens/05-reddit-post.png",
    alt: "Reddit comments and the comment action bar in RSSum",
    caption: "Comment action bar",
    controls: [
      { x: 62.5, y: 17.8, icon: "✎", title: "Add a top-level comment", text: "Open the reply composer and publish a new comment on the post.", tip: "Reddit authentication is required for posting." },
      { x: 68.0, y: 17.8, icon: "⇅", title: "Sort comments", text: "Reorder the discussion with Reddit comment sorts such as Best, New, Top, or Controversial.", tip: "The selected sort is shown beside the compose button." },
      { x: 77.6, y: 17.8, icon: "❝", title: "Summarize comments", text: "Generate a focused summary of the loaded comment discussion.", tip: "The summary shows the overall sentiment and comment count at the top." },
      { x: 86.3, y: 17.8, icon: "?", title: "Ask about the discussion", text: "Open the Ask bar grounded in the post and its loaded comments.", tip: "Ask about consensus, disagreements, or specific details." },
      { x: 91.4, y: 17.8, icon: "◔", title: "Run deep analysis", text: "Analyze the discussion’s themes, sentiment, and patterns beyond a short summary.", tip: "Uses your Summary Source." },
      { x: 95.2, y: 17.8, icon: "W❝", title: "Send to your web model", text: "Open a menu to send a comment summary or deep analysis to ChatGPT or Gemini.", tip: "The next screen shows this menu." },
      { x: 18.0, y: 60.6, icon: "↕", title: "Act on a comment", text: "Vote, reply, share, or open more actions directly beneath each comment.", tip: "Replies remain attached to their parent comment in the thread." },
      { x: 95.6, y: 25.7, icon: "⌃", title: "Collapse a thread", text: "Fold a comment and its replies out of the way.", tip: "Tap again to expand it." }
    ]
  },
  {
    title: "Send the discussion to your web model",
    short: "Web actions",
    summary: "Use ChatGPT or Gemini for a comment summary or deep analysis.",
    image: "assets/screens/05b-reddit-web-menu.png",
    alt: "The Send to ChatGPT menu over Reddit comments",
    caption: "Web model menu",
    controls: [
      { x: 85.6, y: 18.6, icon: "W", title: "Which web model", text: "The heading names the Web AI chosen in Settings, so you always know where the request goes.", tip: "Change it in Settings → Web AI; the heading switches between ChatGPT and Gemini." },
      { x: 87.2, y: 24.9, icon: "W❝", title: "Comment summary", text: "Send the loaded comments to your web model for a summary.", tip: "The result is shown in the app like any other summary." },
      { x: 88.8, y: 31.9, icon: "◔", title: "Deep analysis", text: "Run the deep analysis of the discussion with your web model instead of your Summary Source.", tip: "Useful for very long threads when your main provider is a small local model." }
    ]
  },
  {
    title: "Ask the discussion",
    short: "Reddit Q&A",
    summary: "Question a post and its comments with either your normal provider or your web model.",
    image: "assets/screens/06-reddit-ask.png",
    alt: "Reddit Ask bar with suggestion chips in RSSum",
    caption: "Reddit Ask bar",
    controls: [
      { x: 35.0, y: 15.6, icon: "?", title: "Write a discussion question", text: "Ask about the post, a comment, the community’s response, or points of disagreement.", tip: "The answer is grounded in the comments the app has loaded." },
      { x: 23.9, y: 21.8, icon: "✦", title: "Start with a suggestion", text: "Tap Key points, Where do people disagree?, or Consensus to ask that question right away.", tip: "The chips disappear as soon as you start typing." },
      { x: 88.4, y: 15.6, icon: "W?", title: "Ask your web model", text: "Send your question, the post, and loaded comments to ChatGPT or Gemini.", tip: "Enter a question first to enable this action." },
      { x: 92.0, y: 15.6, icon: "↑", title: "Send to the normal provider", text: "Submit the question through the Summary Source configured in Settings.", tip: "The button turns orange once the field contains text." },
      { x: 96.0, y: 15.6, icon: "×", title: "Close the Ask bar", text: "Hide the Ask bar and clear its draft.", tip: "The post and loaded comments stay open." },
      { x: 50.0, y: 94.8, icon: "×", title: "Toggle Ask from the shortcut bar", text: "When the Ask bar is open, the middle shortcut changes from a question mark to a close button.", tip: "The other shortcuts still scroll to the top and summarize comments." }
    ]
  },
  {
    title: "Choose what to summarize",
    short: "Batch scope",
    summary: "Control which slice of a subreddit becomes the next batch summary.",
    image: "assets/screens/07-summary-scope.png",
    alt: "Reddit batch summary scope picker showing New, Hot, Top Day, and Top Week",
    caption: "Reddit batch-summary scope",
    controls: [
      { x: 59.6, y: 49.3, icon: "N", title: "New", text: "Summarize the unread posts currently available for this subreddit.", tip: "The line above the buttons tells you how many unread posts are ready." },
      { x: 66.4, y: 49.3, icon: "H", title: "Hot", text: "Fetch and summarize up to 50 posts from Reddit’s current Hot ranking.", tip: "Use Hot for what the community is actively surfacing now." },
      { x: 57.4, y: 56.6, icon: "D", title: "Top Day", text: "Build the batch from the subreddit’s highest-ranked posts of the day.", tip: "This is a focused snapshot of the last 24 hours." },
      { x: 67.5, y: 56.6, icon: "W", title: "Top Week", text: "Build the batch from the subreddit’s highest-ranked posts of the week.", tip: "Use this when a daily view is too narrow." },
      { x: 62.7, y: 63.6, icon: "×", title: "Cancel", text: "Dismiss the scope picker without starting a summary.", tip: "Tapping outside the panel also cancels it." }
    ]
  },
  {
    title: "See the whole picture",
    short: "Overall summary",
    summary: "Summarize many sources into one navigable overview, ask questions across them, then listen or transform it.",
    image: "assets/screens/08-overall-summary.png",
    alt: "A draggable Overall Summary panel over a Reddit feed",
    caption: "Overall Summary workspace",
    controls: [
      { x: 30.3, y: 19.2, icon: "≡", title: "Drag the summary panel", text: "Use the handle area to move the floating summary workspace without closing it.", tip: "The panel stays above the feed so you can compare overview and sources." },
      { x: 35.9, y: 19.2, icon: "⌂", title: "Return to the overview", text: "Jump back to the Overall Summary after following a numbered reference.", tip: "Before an overview exists, this spot shows ❝ to generate it." },
      { x: 40.2, y: 19.2, icon: "↻", title: "Retry the batch", text: "Run the last batch request again with the same source context.", tip: "Use Retry if loading was interrupted or a provider failed." },
      { x: 43.1, y: 19.2, icon: "⧉", title: "Copy the overview", text: "Copy the Overall Summary and its per-item summaries to the clipboard.", tip: "Disabled until there is summary content." },
      { x: 49.2, y: 19.2, icon: "?", title: "Ask across the batch", text: "Open a question field grounded in all of the saved article or Reddit summaries.", tip: "The Batch Q&A screen shows it open." },
      { x: 56.1, y: 19.2, icon: "✦", title: "Create", text: "Turn the batch into a Whiteboard, an Infographic, or a two-host Podcast, using your Summary Source.", tip: "Podcast opens the studio with the evidence already captured; nothing is fetched again." },
      { x: 62.4, y: 19.2, icon: "W❝", title: "Send to your web model", text: "Send the Overall Summary, Whiteboard, or Infographic prompt to ChatGPT or Gemini instead.", tip: "Hidden when Web AI is already your main provider." },
      { x: 66.8, y: 19.2, icon: "−", title: "Minimize", text: "Hide the panel while keeping its summaries and context.", tip: "Reopen it from the floating summary control." },
      { x: 69.6, y: 19.2, icon: "×", title: "Close and clear", text: "Dismiss the workspace and clear its saved context.", tip: "Use Minimize instead when you plan to return." },
      { x: 62.8, y: 38.1, icon: "▶", title: "Listen", text: "Play reads the overview with the cloud voice; the speaker uses your on-device voice.", tip: "While audio plays, these turn into a single stop button." },
      { x: 43.9, y: 71.2, icon: "1", title: "Follow a source reference", text: "Tap a numbered reference to jump to that item’s own summary or open its source.", tip: "Use the Home button to return to the combined overview." }
    ]
  },
  {
    title: "Ask about any passage",
    short: "Text actions",
    summary: "Select summary text and send just that passage to the model you choose.",
    image: "assets/screens/09-selection-actions.png",
    alt: "iOS text-selection menu showing Ask AI and Ask AI Web",
    caption: "Selectable summary text and AI actions",
    controls: [
      { x: 35.8, y: 55.0, icon: "Aa", title: "Select the exact passage", text: "Drag the blue selection handles around the words you want to investigate.", tip: "Standard iOS actions such as Copy, Look Up, Translate, Search Web, Speak, and Share remain available." },
      { x: 50.0, y: 55.1, icon: "?", title: "Ask AI", text: "Send only the selected passage, plus relevant summary context, to your normal Summary Source.", tip: "This is ideal for explaining a claim without questioning the entire batch." },
      { x: 49.8, y: 60.8, icon: "W?", title: "Ask AI Web", text: "Send the selected passage and context to the Web AI destination configured in Settings.", tip: "Use this when you specifically want ChatGPT or Gemini’s web interface." },
      { x: 50.2, y: 27.0, icon: "↗", title: "Use standard iOS actions", text: "Copy, define, translate, search, speak, or share the selection with familiar system tools.", tip: "RSSum adds AI actions without replacing the native selection menu." }
    ]
  },
  {
    title: "Ask across every source",
    short: "Batch Q&A",
    summary: "Question the overall picture using all saved summaries as shared context.",
    image: "assets/screens/10-overall-ask.png",
    alt: "Overall Summary panel with the batch question field open",
    caption: "Overall Summary Q&A",
    controls: [
      { x: 49.2, y: 19.2, icon: "?", title: "Toggle batch Q&A", text: "Show or hide the question field for the current collection of Reddit discussions or articles.", tip: "Ask turns blue while the question field is open." },
      { x: 50.0, y: 35.2, icon: "…", title: "Write a cross-source question", text: "Ask for comparisons, shared themes, disagreements, or evidence across the whole batch.", tip: "A generated Overall Summary makes broad questions more reliable." },
      { x: 32.7, y: 42.4, icon: "?", title: "Ask your Summary Source", text: "Send the question to the provider selected in Settings.", tip: "Enabled once the field contains text." },
      { x: 36.2, y: 42.4, icon: "W?", title: "Ask your web model", text: "Send the same question and batch context to ChatGPT or Gemini.", tip: "Hidden when Web AI is already your main provider." },
      { x: 39.8, y: 42.4, icon: "×", title: "Clear the question", text: "Reset the question and answer while leaving the field open.", tip: "Use it to start a fresh line of inquiry." },
      { x: 62.8, y: 60.8, icon: "▶", title: "Listen to the overview", text: "Read the Overall Summary aloud while the question field stays open.", tip: "Playback does not change your question draft." }
    ]
  },
  {
    title: "Turn a batch into a podcast",
    short: "Podcast",
    summary: "Generate a grounded two-host episode from saved summaries, then listen in the embedded podcast player.",
    image: "assets/screens/11-podcast.png",
    alt: "RSSum Batch Podcast creation screen",
    caption: "Batch Podcast studio",
    controls: [
      { x: 3.5, y: 6.6, icon: "−", title: "Minimize the studio", text: "Hide Batch Podcast while preserving its current context and progress.", tip: "Use Close only when you are finished with the studio." },
      { x: 96.8, y: 6.6, icon: "×", title: "Close Batch Podcast", text: "Dismiss the podcast studio and return to the app.", tip: "Any already-saved episode remains available." },
      { x: 23.5, y: 46.7, icon: "A", title: "Choose the first host", text: "Select the voice used for the first speaker in the generated conversation.", tip: "Voice choices affect only this episode." },
      { x: 32.0, y: 46.7, icon: "M", title: "Choose the second host", text: "Select a contrasting voice for the second speaker.", tip: "Two distinct voices make the scripted exchange easier to follow." },
      { x: 48.0, y: 56.2, icon: "↔", title: "Set playback speed", text: "Adjust the speaking speed for this podcast episode.", tip: "The current multiplier appears at the right of the slider." },
      { x: 28.0, y: 68.7, icon: "✦", title: "Generate the script", text: "Create a grounded two-host script from the current batch’s saved evidence.", tip: "The source and evidence counts show exactly what grounds the episode." },
      { x: 49.8, y: 84.0, icon: "▤", title: "Episode workspace", text: "After generation, the script, embedded player, playback, and export controls appear in this area.", tip: "The empty state confirms that no script has been generated yet." }
    ]
  },
  {
    title: "Shape the experience",
    short: "Settings",
    summary: "Choose the appearance, enable YouTube, and decide which intelligence powers summaries.",
    image: "assets/screens/12-settings.png",
    alt: "RSSum Settings showing appearance, YouTube support, and Summary Source",
    caption: "General and provider settings",
    controls: [
      { x: 69.8, y: 13.7, icon: "✓", title: "Done", text: "Close Settings and return to the screen behind it.", tip: "Most settings are saved as soon as you change them." },
      { x: 50.0, y: 29.4, icon: "◐", title: "Choose an appearance", text: "Follow the system appearance or force the app into Light or Dark mode.", tip: "The selected style applies across the app." },
      { x: 65.5, y: 44.5, icon: "YT", title: "Enable YouTube support", text: "Allow public channel search, subscriptions, in-app playback, caption summaries, and Q&A.", tip: "Turning this off leaves existing RSS and Reddit features unchanged." },
      { x: 59.7, y: 75.8, icon: "AI", title: "Choose the Summary Source", text: "Select the provider that generates normal article, Reddit, overall-summary, and Q&A results.", tip: "Provider-specific controls appear farther down the form." },
      { x: 4.2, y: 96.0, icon: "⚙", title: "Open Settings", text: "The Settings row at the bottom of the sidebar opens this panel from your library.", tip: "On smaller screens it remains available from the app’s navigation." },
      { x: 5.0, y: 89.8, icon: "+", title: "Add a subscription", text: "Subscribe to another RSS feed, subreddit, or—when enabled—YouTube channel.", tip: "Your subscription library can sync through iCloud." }
    ]
  },
  {
    title: "Connect your AI tools",
    short: "AI setup",
    summary: "Select the normal provider, choose a Web AI destination, and manage persistent sessions.",
    image: "assets/screens/13-ai-settings.png",
    alt: "RSSum Settings showing Summary Source and Web AI sessions",
    caption: "AI provider and Web AI session settings",
    controls: [
      { x: 70.0, y: 13.7, icon: "✓", title: "Done", text: "Close Settings after configuring your providers.", tip: "Selections and login-session actions take effect immediately." },
      { x: 60.0, y: 23.7, icon: "AI", title: "Select the normal Summary Source", text: "Choose local, cloud, bridge, or other supported processing for the app’s standard AI buttons.", tip: "The description beneath the menu explains the selected route." },
      { x: 50.0, y: 41.0, icon: "↔", title: "Choose a Web AI destination", text: "Select whether explicit web actions open ChatGPT or Gemini in the in-app browser.", tip: "This choice does not replace your normal Summary Source." },
      { x: 40.0, y: 67.0, icon: "↪", title: "Log in to ChatGPT", text: "Open the in-app Web AI browser and establish a reusable ChatGPT session.", tip: "The login stays inside RSSum’s persistent web session." },
      { x: 57.0, y: 67.0, icon: "↺", title: "Reset ChatGPT", text: "Clear the persistent ChatGPT web session when you need to change accounts or recover a login.", tip: "Reset affects the in-app web session, not the ChatGPT app." },
      { x: 39.0, y: 73.0, icon: "↪", title: "Log in to Gemini", text: "Establish a reusable Gemini session for explicit Web AI actions.", tip: "Once signed in, future sends can reuse the session." },
      { x: 55.0, y: 73.0, icon: "↺", title: "Reset Gemini", text: "Clear the persistent Gemini web session.", tip: "Use Reset if the wrong account is active or the session becomes stale." },
      { x: 49.5, y: 86.0, icon: "⇄", title: "Configure a bridge when required", text: "Provider-specific bridge fields appear below when the selected Summary Source needs a Mac-hosted service.", tip: "Direct local and cloud providers do not all require the same fields." }
    ]
  },
  {
    title: "Keep storage under control",
    short: "Storage",
    summary: "Inspect cached data, safely clear disposable files, and keep downloaded models.",
    image: "assets/screens/14-storage.png",
    alt: "RSSum cache management and storage breakdown settings",
    caption: "Cache and storage management",
    controls: [
      { x: 70.2, y: 13.7, icon: "✓", title: "Done", text: "Close Settings and return to the app.", tip: "Cleanup operations report their status before you leave." },
      { x: 50.0, y: 29.1, icon: "⌫", title: "Clear all removable caches", text: "Delete disposable app caches while keeping completed MLX model downloads.", tip: "The removable amount is shown above the button." },
      { x: 50.0, y: 43.5, icon: "⇩", title: "Clean failed model downloads", text: "Remove only incomplete .download files left by interrupted model transfers.", tip: "Completed local models are kept." },
      { x: 67.8, y: 72.1, icon: "↻", title: "Refresh the storage breakdown", text: "Recalculate the size of each storage category in the app container.", tip: "Refresh after a cleanup to confirm the reclaimed space." },
      { x: 67.8, y: 77.1, icon: "⌫", title: "Delete one storage category", text: "Remove a specific disposable category with its red trash button.", tip: "Check the category name and size before confirming." },
      { x: 39.0, y: 79.9, icon: "▤", title: "Inspect storage by category", text: "See which caches, models, and app-container areas are using space.", tip: "Removable data is listed separately from assets you may want to keep." }
    ]
  }
];

let currentScreen = 0;
let currentControl = 0;

const $ = (selector) => document.querySelector(selector);
const chapterList = $("#chapterList");
const hotspotLayer = $("#hotspotLayer");
const controlList = $("#controlList");
const stepDots = $("#stepDots");
const stage = $("#screenStage");
const inspector = $(".inspector");

function pad(number) {
  return String(number).padStart(2, "0");
}

function scrollBehavior() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth";
}

function buildNavigation() {
  screens.forEach((screen, index) => {
    const chapter = document.createElement("button");
    chapter.type = "button";
    chapter.className = "chapter-button";
    chapter.innerHTML = `<span>${pad(index + 1)}</span><span>${screen.short}</span>`;
    chapter.setAttribute("aria-label", `Screen ${index + 1}: ${screen.title}`);
    chapter.addEventListener("click", () => showScreen(index));
    chapterList.appendChild(chapter);

    const dot = document.createElement("button");
    dot.type = "button";
    dot.className = "step-dot";
    dot.setAttribute("aria-label", `Go to screen ${index + 1}: ${screen.title}`);
    dot.addEventListener("click", () => showScreen(index));
    stepDots.appendChild(dot);
  });
}

function buildControls(screen) {
  hotspotLayer.replaceChildren();
  controlList.replaceChildren();

  screen.controls.forEach((control, index) => {
    const marker = document.createElement("button");
    marker.type = "button";
    marker.className = "hotspot";
    marker.style.left = `${control.x}%`;
    marker.style.top = `${control.y}%`;
    marker.textContent = index + 1;
    marker.title = control.title;
    marker.setAttribute("aria-label", `${index + 1}. ${control.title}`);
    marker.addEventListener("click", () => showControl(index));
    hotspotLayer.appendChild(marker);

    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "control-chip";
    chip.textContent = index + 1;
    chip.title = control.title;
    chip.setAttribute("aria-label", `${index + 1}. ${control.title}`);
    chip.addEventListener("click", () => showControl(index));
    controlList.appendChild(chip);
  });
}

function showControl(index, animate = true) {
  const screen = screens[currentScreen];
  currentControl = Math.max(0, Math.min(index, screen.controls.length - 1));
  const control = screen.controls[currentControl];

  hotspotLayer.querySelectorAll(".hotspot").forEach((node, itemIndex) => {
    node.classList.toggle("active", itemIndex === currentControl);
    node.setAttribute("aria-pressed", itemIndex === currentControl ? "true" : "false");
  });
  controlList.querySelectorAll(".control-chip").forEach((node, itemIndex) => {
    node.classList.toggle("active", itemIndex === currentControl);
    node.setAttribute("aria-pressed", itemIndex === currentControl ? "true" : "false");
  });

  $("#controlCount").textContent = `Control ${currentControl + 1} of ${screen.controls.length}`;
  $("#controlSymbol").textContent = control.icon;
  $("#controlTitle").textContent = control.title;
  $("#controlDescription").textContent = control.text;
  $("#controlTip span").textContent = control.tip;

  if (animate) {
    inspector.classList.remove("is-changing");
    void inspector.offsetWidth;
    inspector.classList.add("is-changing");
  }
}

function showScreen(index, options = {}) {
  currentScreen = Math.max(0, Math.min(index, screens.length - 1));
  currentControl = 0;
  const screen = screens[currentScreen];

  $("#stepKicker").textContent = `Screen ${pad(currentScreen + 1)} of ${screens.length}`;
  $("#stepTitle").textContent = screen.title;
  $("#stepSummary").textContent = screen.summary;
  $("#screenImage").src = screen.image;
  $("#screenImage").alt = screen.alt;
  $("#screenCaption").textContent = screen.caption;
  $("#progressBar").style.height = `${((currentScreen + 1) / screens.length) * 100}%`;

  chapterList.querySelectorAll(".chapter-button").forEach((node, itemIndex) => {
    node.classList.toggle("active", itemIndex === currentScreen);
    node.setAttribute("aria-current", itemIndex === currentScreen ? "step" : "false");
  });
  stepDots.querySelectorAll(".step-dot").forEach((node, itemIndex) => {
    node.classList.toggle("active", itemIndex === currentScreen);
    node.setAttribute("aria-current", itemIndex === currentScreen ? "step" : "false");
  });

  $("#prevStep").disabled = currentScreen === 0;
  $("#nextStep").textContent = currentScreen === screens.length - 1 ? "Finish ✓" : "Next →";
  buildControls(screen);
  showControl(0, false);

  stage.classList.remove("is-changing");
  void stage.offsetWidth;
  stage.classList.add("is-changing");

  // Keep the active chapter visible without scrolling the entire document on load.
  const activeChapter = chapterList.children[currentScreen];
  const rail = chapterList.parentElement;
  if (activeChapter && rail.scrollWidth > rail.clientWidth) {
    const offset = activeChapter.getBoundingClientRect().left - rail.getBoundingClientRect().left;
    rail.scrollTo({ left: rail.scrollLeft + offset - 8, behavior: scrollBehavior() });
  }
  if (options.scroll) {
    $("#guide").scrollIntoView({ behavior: scrollBehavior(), block: "start" });
  }
}

function beginTour() {
  showScreen(0, { scroll: true });
}

$("#prevStep").addEventListener("click", () => showScreen(currentScreen - 1));
$("#nextStep").addEventListener("click", () => {
  if (currentScreen === screens.length - 1) {
    $(".onboarding-note").scrollIntoView({ behavior: scrollBehavior() });
  } else {
    showScreen(currentScreen + 1);
  }
});
$("#startTour").addEventListener("click", beginTour);
$("#startTourTop").addEventListener("click", beginTour);
$("#restartTour").addEventListener("click", beginTour);

const gatewayTabs = [...document.querySelectorAll(".gateway-tab")];
gatewayTabs.forEach((tab, index) => {
  tab.addEventListener("click", () => {
    const selected = tab.dataset.gateway;
    document.querySelectorAll(".gateway-tab").forEach((item) => {
      const isActive = item === tab;
      item.classList.toggle("active", isActive);
      item.setAttribute("aria-selected", isActive ? "true" : "false");
      item.tabIndex = isActive ? 0 : -1;
    });
    document.querySelectorAll(".gateway-panel").forEach((panel) => {
      const isActive = panel.id === `${selected}Gateway`;
      panel.hidden = !isActive;
      panel.classList.toggle("active", isActive);
    });
  });
  tab.addEventListener("keydown", (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const next = event.key === "Home" ? 0 : event.key === "End" ? gatewayTabs.length - 1 : (index + (event.key === "ArrowRight" ? 1 : -1) + gatewayTabs.length) % gatewayTabs.length;
    gatewayTabs[next].focus();
    gatewayTabs[next].click();
  });
});

document.querySelectorAll(".copy-command").forEach((button) => {
  button.addEventListener("click", async () => {
    const originalLabel = button.textContent;
    try {
      await navigator.clipboard.writeText(button.dataset.copy || "");
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select command";
    }
    window.setTimeout(() => { button.textContent = originalLabel; }, 1600);
  });
});

document.addEventListener("keydown", (event) => {
  const tag = document.activeElement?.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
  if (!document.activeElement?.closest("#guide")) return;
  if (!["ArrowRight", "ArrowLeft", "ArrowDown", "ArrowUp"].includes(event.key)) return;
  event.preventDefault();
  if (event.key === "ArrowRight") showScreen(currentScreen + 1);
  if (event.key === "ArrowLeft") showScreen(currentScreen - 1);
  if (event.key === "ArrowDown") showControl(currentControl + 1);
  if (event.key === "ArrowUp") showControl(currentControl - 1);
});

buildNavigation();
showScreen(0);
