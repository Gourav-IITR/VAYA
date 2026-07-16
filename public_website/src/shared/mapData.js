// Bhubaneswar Map Data and Pathfinding

export const LANDMARKS = [
  {
    id: 'kiit',
    name: 'KIIT Campus',
    name_or: 'କିଟ୍ କ୍ୟାମ୍ପସ',
    name_hi: 'केआईआईटी परिसर',
    x: 480,
    y: 80,
    gpsLat: 20.3530,
    gpsLng: 85.8260,
    desc: 'KIIT Square / Patia Area'
  },
  {
    id: 'patia_sq',
    name: 'Patia Square',
    name_or: 'ପଟିଆ ଛକ',
    name_hi: 'पटिया चौराहा',
    x: 480,
    y: 180,
    gpsLat: 20.3390,
    gpsLng: 85.8170,
    desc: 'Patia main junction'
  },
  {
    id: 'cspur',
    name: 'Chandrasekharpur',
    name_or: 'ଚନ୍ଦ୍ରଶେଖରପୁର',
    name_hi: 'चंद्रशेखरपुर',
    x: 480,
    y: 280,
    gpsLat: 20.3180,
    gpsLng: 85.8160,
    desc: 'C.S. Pur commercial area'
  },
  {
    id: 'jayadev_vihar',
    name: 'Jayadev Vihar',
    name_or: 'ଜୟଦେବ ବିହାର',
    name_hi: 'जयदेव विहार',
    x: 400,
    y: 380,
    gpsLat: 20.2950,
    gpsLng: 85.8140,
    desc: 'Jayadev Vihar Square'
  },
  {
    id: 'acharya_vihar',
    name: 'Acharya Vihar',
    name_or: 'ଆଚାର୍ଯ୍ୟ ବିହାର',
    name_hi: 'आचार्य विहार',
    x: 520,
    y: 380,
    gpsLat: 20.2980,
    gpsLng: 85.8250,
    desc: 'Acharya Vihar Square'
  },
  {
    id: 'vani_vihar',
    name: 'Vani Vihar Square',
    name_or: 'ବାଣୀ ବିହାର ଛକ',
    name_hi: 'वाणी विहार चौराहा',
    x: 580,
    y: 460,
    gpsLat: 20.2910,
    gpsLng: 85.8430,
    desc: 'Utkal University Entrance'
  },
  {
    id: 'master_canteen',
    name: 'Master Canteen',
    name_or: 'ମାଷ୍ଟର କ୍ୟାଣ୍ଟିନ',
    name_hi: 'मास्टर कैंटीन',
    x: 580,
    y: 580,
    gpsLat: 20.2720,
    gpsLng: 85.8420,
    desc: 'Bhubaneswar Railway Station'
  },
  {
    id: 'capital_hospital',
    name: 'Capital Hospital',
    name_or: 'କ୍ୟାପିଟାଲ ହସ୍ପିଟାଲ',
    name_hi: 'कैपिटल अस्पताल',
    x: 420,
    y: 580,
    gpsLat: 20.2640,
    gpsLng: 85.8190,
    desc: 'Unit-6 Medical Center'
  },
  {
    id: 'airport',
    name: 'Biju Patnaik Airport',
    name_or: 'ବିଜୁ ପଟ୍ଟନାୟକ ବିମାନବନ୍ଦର',
    name_hi: 'बीजू पटनायक हवाई अड्डा',
    x: 280,
    y: 650,
    gpsLat: 20.2520,
    gpsLng: 85.8140,
    desc: 'BBI Airport Terminal'
  },
  {
    id: 'khandagiri',
    name: 'Khandagiri Square',
    name_or: 'ଖଣ୍ଡଗିରି ଛକ',
    name_hi: 'खंडगिरी चौराहा',
    x: 180,
    y: 500,
    gpsLat: 20.2580,
    gpsLng: 85.7760,
    desc: 'Khandagiri & Udayagiri Caves'
  },
  {
    id: 'baramunda',
    name: 'Baramunda Bus Stand',
    name_or: 'ବରମୁଣ୍ଡା ବସଷ୍ଟାଣ୍ଡ',
    name_hi: 'बरमुंडा बस स्टैंड',
    x: 260,
    y: 410,
    gpsLat: 20.2740,
    gpsLng: 85.7950,
    desc: 'ISBT Baramunda'
  }
];

export const findNearestLandmark = (lat, lng) => {
  let nearest = null;
  let minDist = Infinity;
  LANDMARKS.forEach(l => {
    if (l.gpsLat && l.gpsLng) {
      const dist = Math.hypot(l.gpsLat - lat, l.gpsLng - lng);
      if (dist < minDist) {
        minDist = dist;
        nearest = l;
      }
    }
  });
  return nearest;
};

// Roads representing connected lanes (weighted graph)
export const ROADS = [
  { from: 'kiit', to: 'patia_sq', name: 'Patia Road' },
  { from: 'patia_sq', to: 'cspur', name: 'Nandan Kanan Road' },
  { from: 'cspur', to: 'jayadev_vihar', name: 'Nandan Kanan Road' },
  { from: 'jayadev_vihar', to: 'acharya_vihar', name: 'NH16 Expressway' },
  { from: 'acharya_vihar', to: 'vani_vihar', name: 'NH16 Expressway' },
  { from: 'vani_vihar', to: 'master_canteen', name: 'Janpath Road' },
  { from: 'jayadev_vihar', to: 'baramunda', name: 'NH16 West' },
  { from: 'baramunda', to: 'khandagiri', name: 'NH16 South-West' },
  { from: 'khandagiri', to: 'airport', name: 'Khandagiri Road' },
  { from: 'airport', to: 'capital_hospital', name: 'Airport Bypass' },
  { from: 'capital_hospital', to: 'master_canteen', name: 'Rajpath Road' },
  { from: 'baramunda', to: 'capital_hospital', name: 'Unit 8 Main Road' },
  { from: 'cspur', to: 'acharya_vihar', name: 'Sainik School Road' }
];

// Graph Adjacency List building
const graph = {};
LANDMARKS.forEach(l => {
  graph[l.id] = [];
});
ROADS.forEach(r => {
  const fromNode = LANDMARKS.find(l => l.id === r.from);
  const toNode = LANDMARKS.find(l => l.id === r.to);
  if (fromNode && toNode) {
    const dist = Math.hypot(fromNode.x - toNode.x, fromNode.y - toNode.y);
    graph[r.from].push({ node: r.to, dist });
    graph[r.to].push({ node: r.from, dist });
  }
});

// Simple Dijkstra implementation
export const getPath = (startId, endId) => {
  if (startId === endId) return [startId];
  
  const distances = {};
  const previous = {};
  const queue = [];
  
  LANDMARKS.forEach(l => {
    distances[l.id] = Infinity;
    previous[l.id] = null;
  });
  
  distances[startId] = 0;
  queue.push({ id: startId, priority: 0 });
  
  while (queue.length > 0) {
    // Sort queue by priority (distance)
    queue.sort((a, b) => a.priority - b.priority);
    const { id: u } = queue.shift();
    
    if (u === endId) {
      const path = [];
      let curr = endId;
      while (curr) {
        path.unshift(curr);
        curr = previous[curr];
      }
      return path;
    }
    
    if (distances[u] === Infinity) break;
    
    for (const neighbor of graph[u]) {
      const alt = distances[u] + neighbor.dist;
      if (alt < distances[neighbor.node]) {
        distances[neighbor.node] = alt;
        previous[neighbor.node] = u;
        queue.push({ id: neighbor.node, priority: alt });
      }
    }
  }
  
  return [startId, endId]; // Fallback
};

// Interpolates points along a path of landmark IDs (using GPS coordinates)
export const getPathCoordinates = (pathIds) => {
  return pathIds.map(id => {
    const landmark = LANDMARKS.find(l => l.id === id);
    return landmark ? { lat: landmark.gpsLat, lng: landmark.gpsLng } : null;
  }).filter(Boolean);
};
