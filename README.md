📘 PCCOE Venue Booking Portal
🏫 Project Overview

The PCCOE Venue Booking Portal is a web-based application designed to manage and streamline the booking of college venues such as auditoriums, seminar halls, labs, and other facilities.

The system allows faculty and administrators to efficiently handle booking requests, track status, and manage venue availability in real time.

🎯 Key Features
🔐 Authentication System
Secure login using Supabase Authentication
Session-based access control
Redirects unauthorized users
👤 Role-Based Access
Faculty → Can request bookings
Admin → Can approve/reject bookings
Staff → View-only access
📅 Booking System
Select venue, date, and time slots
Real-time slot availability checking
Conflict prevention logic
Booking status tracking (Pending / Accepted / Rejected)
🕐 Time Slot Management
Dynamic slot loading from database
Visual indicators:
🟢 Available
🟡 Pending
🔴 Booked
🧠 Smart UI Features
Character counter for event description
Theme toggle (light/dark mode)
Modal popups and interactive forms
Image-based venue browsing
📊 Dashboard
Overview of bookings
Quick navigation
Venue cards with booking options
🛠️ Tech Stack
Frontend:
HTML5
CSS3 (Grid, Flexbox)
JavaScript (ES6)
Backend:
Supabase (PostgreSQL + Auth)
API:
Supabase client SDK
🗂️ Project Structure
PCCOE-Booking-System/
│
├── index.html            # Login Page
├── dashboard.html        # Main Dashboard
├── book.html             # Booking Page
├── yourbooking.html      # User Bookings
├── accept.html           # Admin Panel
│
├── style.css             # Stylesheet
├── script.js             # JS Logic (if separated)
│
├── images/
│   ├── pccoe.jpg
│   ├── campus.jpg
│
├── SQL/
│   ├── booking_queries.sql
│
└── README.md
⚙️ How It Works
User logs in via Supabase authentication
System verifies role and redirects to dashboard
User selects venue and date
Available time slots are fetched dynamically
User submits booking request
Admin reviews request:
Accept → Booking confirmed
Reject → Booking declined
Status is updated in real time
🔄 Database Overview

Main Tables:

profiles → User information
booking_requests → Booking details
slots → Available time slots
booking_slots → Mapping between bookings and slots
🚀 Installation & Setup
Clone the repository
git clone https://github.com/your-repo/pccoe-booking-system.git
Open project folder
Run index.html in browser
Connect to Supabase:
Replace API keys if needed
Ensure database tables exist
⚠️ Important Notes
Supabase anon key is used for client-side access
Role-based UI controls visibility of features
Slot conflict handling is implemented before booking
🎓 Academic Use

This project is developed as part of:

Course: FSDL 1
Class: SY BTech
Semester: II
Year: 2025–26

📌 Future Enhancements
Email notifications for booking status
Calendar view integration
Payment gateway for paid bookings
Mobile responsive improvements


📄 License

This project is for academic purposes only.
