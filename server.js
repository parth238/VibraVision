require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { GoogleGenerativeAI } = require('@google/generative-ai');

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.static(__dirname));

// Initialize Gemini API
const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY);

// In-Memory Storage for Hackathon Speed
let latestTelemetry = {
    frequency: 0.00,
    intensity: 0.00,
    status: "WAITING FOR SENSOR",
    aiReport: "System idle. Awaiting baseline telemetry from edge device."
};

// ENDPOINT 1: Flutter sends data HERE
app.post('/api/telemetry', async (req, res) => {
    const { frequency, intensity } = req.body;

    console.log(`[+] Received Telemetry: ${frequency} Hz | ${intensity} AU`);

    try {
        const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash" });

        const prompt = `You are GenTwin, an expert industrial reliability AI. An edge sensor on a heavy factory fan (Asset HAV-402) just reported a structural sway frequency of ${frequency} Hz and a displacement intensity of ${intensity} AU.
        
        Rule 1: If intensity is > 0.150 AU, treat it as a CRITICAL LOOSENESS ALARM caused by vibrating mounting bolts.
        Rule 2: If intensity is < 0.150 AU, treat it as HEALTHY baseline sway.
        
        Generate a concise, 3-sentence diagnostic report and recommend one immediate maintenance action. Be highly professional, technical, and do not use markdown formatting.`;

        const result = await model.generateContent(prompt);
        const aiResponse = result.response.text();

        latestTelemetry = {
            frequency: frequency,
            intensity: intensity,
            status: intensity > 0.150 ? "CRITICAL" : "HEALTHY",
            aiReport: aiResponse
        };

        console.log(`[+] AI Report Generated Successfully.`);
        res.status(200).json({ success: true, message: "Telemetry processed by GenTwin AI" });

    } catch (error) {
        console.error("[-] AI Generation Error:", error);
        res.status(500).json({ error: "AI pipeline failed" });
    }
});

// ENDPOINT 2: React Dashboard fetches data from HERE
app.get('/api/telemetry', (req, res) => {
    res.status(200).json(latestTelemetry);
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, '0.0.0.0', () => {
    console.log(`🚀 GenTwin Backend running on http://localhost:${PORT}`);
});