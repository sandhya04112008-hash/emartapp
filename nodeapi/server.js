const path = require("path");
const express = require("express");
const mongoose = require("mongoose");
const bodyParser = require("body-parser");
const cors = require("cors");
const colors = require("colors");

const mongooseURI = require("./config/keys").mongoURI;

const userRoutes = require("./routes/user");
const shopRoutes = require("./routes/shop");


const app = express();

app.use(cors());
app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: false }));
app.use(express.json());
app.use(express.urlencoded({ extended: false }));
app.use("/images", express.static(path.join(__dirname, "images")));

app.use(express.static(process.cwd()+"/client/dist/client/"));


app.get('/', (req,res) => {
  res.sendFile(process.cwd()+"/client/dist/client/index.html")
})

// Health check endpoint for Kubernetes probes
app.get('/health', (req, res) => {
  res.status(200).json({ status: 'OK', message: 'Server is healthy' });
});

app.use("/api/user", userRoutes);
app.use("/api/shop", shopRoutes);


mongoose
  .connect(mongooseURI, {
    useNewUrlParser: true,
    useUnifiedTopology: true
  })
  .then(() => {
    const port = process.env.PORT || 5000;
    const server = app.listen(port, () => {
      console.log("Server running on port".magenta, colors.yellow(port));
    });
    console.log("\nConnected to".magenta, "E-MART".cyan, "database".magenta);
  })
  .catch(err => console.log("Error connecting to database".cyan, err));
