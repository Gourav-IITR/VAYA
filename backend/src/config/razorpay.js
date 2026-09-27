import Razorpay from 'razorpay';

const RAZORPAY_KEY_ID = process.env.RAZORPAY_KEY_ID;
const RAZORPAY_KEY_SECRET = process.env.RAZORPAY_KEY_SECRET;

let razorpayInstance = null;

if (RAZORPAY_KEY_ID && RAZORPAY_KEY_SECRET) {
  razorpayInstance = new Razorpay({
    key_id: RAZORPAY_KEY_ID,
    key_secret: RAZORPAY_KEY_SECRET,
  });
  console.log('💳 Razorpay Instance initialized successfully.');
} else {
  console.warn('⚠️ Razorpay credentials missing in environment.');
  // Dummy fallback object to prevent null reference errors
  razorpayInstance = {
    orders: {
      create: async () => { throw new Error('Razorpay credentials not configured'); }
    },
    payments: {
      refund: async () => { throw new Error('Razorpay credentials not configured'); }
    },
    paymentLink: {
      create: async () => { throw new Error('Razorpay credentials not configured'); }
    },
    contacts: {
      create: async () => { throw new Error('Razorpay credentials not configured'); }
    },
    fundAccount: {
      create: async () => { throw new Error('Razorpay credentials not configured'); }
    },
    payouts: {
      create: async () => { throw new Error('Razorpay credentials not configured'); }
    }
  };
}

export default razorpayInstance;
