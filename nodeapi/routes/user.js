const express = require("express");
const router = express.Router();
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const nodemailer = require("nodemailer");

const secretOrKey = require("../config/keys").secretOrKey;
const User = require("../models/User"); // User model

const validateRegisterInput = require("../validation/register"); // register validation
const validateLoginInput = require("../validation/login"); // login validation

// Email configuration using environment variables
const emailTransporter = nodemailer.createTransport({
  service: 'gmail',
  auth: {
    user: process.env.EMAIL_USER || 'your-email@gmail.com',
    pass: process.env.EMAIL_PASSWORD || ''
  }
});

// Helper function to send registration email asynchronously
async function sendRegistrationEmail(to, fname) {
  try {
    await emailTransporter.sendMail({
      from: process.env.EMAIL_USER,
      to: to,
      subject: "E_MART Registration Successful",
      text: `Dear ${fname}! Your Registration Finished Successfully.\nWelcome to E-MART Family.\nThank you!`
    });
  } catch (error) {
    console.log("Warning: Could not send registration email:", error.message);
  }
}

// Helper function to send login email asynchronously
async function sendLoginEmail(to, fname) {
  try {
    await emailTransporter.sendMail({
      from: process.env.EMAIL_USER,
      to: to,
      subject: "Login Alert from E-Mart",
      text: `Dear ${fname}, you have logged in successfully at ${new Date().toISOString()}`
    });
  } catch (error) {
    console.log("Warning: Could not send login email:", error.message);
  }
}

//----------------------------------Routes----------------------------------//

// @route   POST /user/register
// @desc    Register user
// @access  Public
router.post("/register", (req, res) => {
  const { errors, isValid } = validateRegisterInput(req.body);
  if (!isValid) return res.status(400).json({ success: false, message: errors });
  User.findOne({ email: req.body.email }).then(user => {
    if (user) {
      errors.email = "Email already exists";
      return res.status(400).json({ success: false, message: errors.email });
    } else {
      User.findOne({ cardId: req.body.cardId }).then(user => {
        if (user) {
          errors.cardId = "Personal ID already exists";
          return res.status(400).json({ success: false, message: errors.cardId });
        } else {

          // Admin Role - Only set to 1 if explicitly provided and user is authorized
          const urole = req.body.role === 1 && req.body.adminKey === process.env.ADMIN_KEY ? 1 : 0;
          // Admin Role
          
          const newUser = new User({


             role:urole,
            cardId: req.body.cardId,
            fname: req.body.fname,
            lname: req.body.lname,
            email: req.body.email,
            password: req.body.password,
            city: req.body.city,
            street: req.body.street
          });
          bcrypt.genSalt(10, (err, salt) => {
            bcrypt.hash(newUser.password, salt, (err, hash) => {
              if (err) throw err;
              newUser.password = hash;
              newUser
                .save()
                .then(user => res.json({ success: true, user }))
                .catch(err => res.status(404).json({ success: false, message: "Could not register user" }));
            });
          });
        }
      });
    }
  });
});

// @route   POST /user/login
// @desc    Login user | Returning JWT Token
// @access  Public
router.post("/login", (req, res) => {
  const { errors, isValid } = validateLoginInput(req.body);
  // if (!isValid) return res.status(400).json({ success: false, message: errors });
  const email = req.body.email;
  const password = req.body.password;
  User.findOne({ email }).then(user => {
    if (!user) {
      errors.email = "User not found";
      return res.status(400).json({ success: false, message: errors.email });
    }
    bcrypt.compare(password, user.password).then(isMatch => {
      if (isMatch) {
        // Create JWT payload
        const payload = {
          id: user.id,
          fname: user.fname,
          lname: user.lname
        };
        // Sign token
        jwt.sign(payload, secretOrKey, (err, token) => {
          if (err) throw err;
          res.json({ success: true, message: "Token was assigned", token: token, user: user });
          
          // Send email asynchronously (non-blocking) - don't wait for it
          sendLoginEmail(email, user.fname).catch(err => 
            console.log("Warning: Could not send login email:", err.message)
          );
        });



      } else {
        errors.password = "Password is incorrect";
        return res.status(400).json({ success: false, message: errors.password });
      }
    });
  });
});

module.exports = router;
