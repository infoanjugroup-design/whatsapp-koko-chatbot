// Sends the koko-chatbot's forgot-password OTP by email. Same Brevo SMTP
// credentials the main koko-website app uses, just as plain env vars here.
//
// Required env vars: SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS
// Optional: SMTP_FROM

import nodemailer from "nodemailer";

function getTransport() {
  const { SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS } = process.env;
  if (!SMTP_HOST || !SMTP_PORT || !SMTP_USER || !SMTP_PASS) {
    throw new Error(
      "Email OTP is not configured: set SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS in the environment."
    );
  }
  return nodemailer.createTransport({
    host: SMTP_HOST,
    port: Number(SMTP_PORT),
    secure: Number(SMTP_PORT) === 465,
    auth: { user: SMTP_USER, pass: SMTP_PASS },
  });
}

export async function sendPasswordResetOtp(toEmail, otp) {
  const transport = getTransport();
  const from = process.env.SMTP_FROM || "koko <no-reply@kokofoods.in>";

  await transport.sendMail({
    from,
    to: toEmail,
    subject: `${otp} is your koko password reset code`,
    text: `Your koko chatbot password reset code is ${otp}. It expires in 10 minutes. If you didn't request this, you can ignore this email.`,
    html: `
      <div style="font-family:sans-serif;max-width:420px;margin:auto">
        <h2 style="color:#0f3d3e">koko 🍿</h2>
        <p>Your password reset code is:</p>
        <p style="font-size:32px;font-weight:bold;letter-spacing:4px;color:#0f3d3e">${otp}</p>
        <p style="color:#666;font-size:13px">This code expires in 10 minutes. If you didn't request this, you can safely ignore this email.</p>
      </div>
    `,
  });
}
