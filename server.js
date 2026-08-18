// Standalone WhatsApp chatbot service for koko.
// Two independent routes — enable either or both depending on which
// WhatsApp channel(s) you're running (see README):
//   POST/GET /api/whatsapp/auto-reply  — free channel via a phone + automation app
//   GET/POST /api/whatsapp/webhook     — official Meta Cloud API number

import express from "express";
import autoReplyRouter from "./src/routes/autoReply.js";
import webhookRouter from "./src/routes/webhook.js";

const app = express();

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Render (and most uptime pingers) hit "/" to confirm the service is alive.
app.get("/", (req, res) => {
  res.type("text/plain").send("whatsapp-koko-chatbot is running.");
});

app.use("/api/whatsapp/auto-reply", autoReplyRouter);
app.use("/api/whatsapp/webhook", webhookRouter);

// Fallback error handler so an unexpected throw doesn't crash the process.
app.use((err, req, res, next) => {
  console.error("Unhandled error:", err);
  if (res.headersSent) return next(err);
  res.status(500).type("text/plain").send("Internal error.");
});

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`whatsapp-koko-chatbot listening on port ${port}`);
});
