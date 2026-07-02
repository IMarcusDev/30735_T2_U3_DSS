import request from 'supertest';
import express from 'express';
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';
import jwt from 'jsonwebtoken';
import userRouter from '../routes/user.routes.js';
import User from '../models/User.js';

const app = express();
app.use(express.json());
app.use('/api/users', userRouter);

let mongoServer;

beforeAll(async () => {
  mongoServer = await MongoMemoryServer.create();
  const uri = mongoServer.getUri();
  await mongoose.connect(uri);
});

afterAll(async () => {
  await mongoose.disconnect();
  await mongoServer.stop();
});

beforeEach(async () => {
  await User.deleteMany({});
});

const generateToken = (userId) => {
  return jwt.sign({ userId }, 'secret', { expiresIn: '1h' });
};

describe('User Routes', () => {
  test('POST / - debe crear usuario correctamente', async () => {
    const res = await request(app)
      .post('/api/users')
      .send({ _id: '123', nombre: 'Juan Pérez', email: 'juan@mail.com' });
    expect(res.status).toBe(201);
    expect(res.body).toHaveProperty('_id', '123');
    expect(res.body).toHaveProperty('nombre', 'Juan Pérez');
    expect(res.body).toHaveProperty('email', 'juan@mail.com');
  });

  test('POST / - debe retornar 400 si falta _id', async () => {
    const res = await request(app)
      .post('/api/users')
      .send({ nombre: 'Ana', email: 'ana@mail.com' });
    expect(res.status).toBe(400);
    expect(res.body.message).toBe('Datos incompletos');
  });

  test('POST / - debe retornar 500 si el email ya existe', async () => {
    await User.create({ _id: '456', nombre: 'Carlos', email: 'duplicado@mail.com' });
    const res = await request(app)
      .post('/api/users')
      .send({ _id: '789', nombre: 'Luis', email: 'duplicado@mail.com' });
    expect(res.status).toBe(500);
    expect(res.body.message).toBe('Error al crear usuario');
  });

  test('GET /me - debe retornar perfil del usuario autenticado', async () => {
    const userId = '123';
    await User.create({ _id: userId, nombre: 'Juan Pérez', email: 'juan@mail.com' });
    const token = generateToken(userId);
    const res = await request(app)
      .get('/api/users/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('_id', userId);
    expect(res.body).not.toHaveProperty('password');
  });

  test('GET /me - debe retornar 401 si no hay token', async () => {
    const res = await request(app).get('/api/users/me');
    expect(res.status).toBe(401);
    expect(res.body.message).toBe('Usuario no autenticado');
  });

  test('GET /me - debe retornar 404 si el usuario no existe', async () => {
    const token = generateToken('999');
    const res = await request(app)
      .get('/api/users/me')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(404);
    expect(res.body.message).toBe('Usuario no encontrado');
  });

  test('PUT /me/update - debe actualizar el nombre correctamente', async () => {
    const userId = '123';
    await User.create({ _id: userId, nombre: 'Juan Pérez', email: 'juan@mail.com' });
    const token = generateToken(userId);
    const res = await request(app)
      .put('/api/users/me/update')
      .set('Authorization', `Bearer ${token}`)
      .send({ nombre: 'Juan Carlos' });
    expect(res.status).toBe(200);
    expect(res.body.nombre).toBe('Juan Carlos');
  });

  test('PUT /me/update - debe retornar 400 si email es inválido', async () => {
    const userId = '123';
    await User.create({ _id: userId, nombre: 'Juan Pérez', email: 'juan@mail.com' });
    const token = generateToken(userId);
    const res = await request(app)
      .put('/api/users/me/update')
      .set('Authorization', `Bearer ${token}`)
      .send({ email: 'correo_invalido' });
    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/email.*valid/);
  });

  test('PUT /me/update - debe retornar 404 si usuario no existe', async () => {
    const token = generateToken('999');
    const res = await request(app)
      .put('/api/users/me/update')
      .set('Authorization', `Bearer ${token}`)
      .send({ nombre: 'Prueba' });
    expect(res.status).toBe(404);
    expect(res.body.message).toBe('Usuario no encontrado');
  });

  test('PUT /me/update - debe actualizar múltiples campos correctamente', async () => {
    const userId = '123';
    await User.create({ _id: userId, nombre: 'Juan Pérez', email: 'juan@mail.com' });
    const token = generateToken(userId);
    const payload = {
      nombre: 'María',
      telefono: '123456789',
      direccion: 'Calle Falsa 123'
    };
    const res = await request(app)
      .put('/api/users/me/update')
      .set('Authorization', `Bearer ${token}`)
      .send(payload);
    expect(res.status).toBe(200);
    expect(res.body.nombre).toBe('María');
    expect(res.body.telefono).toBe('123456789');
    expect(res.body.direccion).toBe('Calle Falsa 123');
  });
});
