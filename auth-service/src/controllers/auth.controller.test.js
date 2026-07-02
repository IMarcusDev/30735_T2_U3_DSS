jest.mock('../models/user.model');
jest.mock('bcryptjs');
jest.mock('jsonwebtoken');
jest.mock('node-fetch');

const User = require('../models/user.model');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const fetch = require('node-fetch');
const controller = require('./auth.controller');

const mockRes = () => {
    const res = {};
    res.status = jest.fn().mockReturnValue(res);
    res.json = jest.fn().mockReturnValue(res);
    return res;
};

beforeEach(() => {
    jest.clearAllMocks();
    process.env.JWT_SECRET = 'test-secret';
    jest.spyOn(console, 'warn').mockImplementation(() => {});
    jest.spyOn(console, 'error').mockImplementation(() => {});
});

afterAll(() => {
    jest.restoreAllMocks();
});

describe('register', () => {
    const req = () => ({
        body: { name: 'Ana', email: 'ana@test.com', password: 'secreta' },
    });

    it('devuelve 400 si el correo ya está registrado', async () => {
        User.findOne.mockResolvedValue({ _id: '1' });
        const res = mockRes();

        await controller.register(req(), res);

        expect(res.status).toHaveBeenCalledWith(400);
        expect(res.json).toHaveBeenCalledWith({ message: 'Correo ya registrado' });
        expect(User.create).not.toHaveBeenCalled();
    });

    it('crea el usuario, sincroniza y devuelve 201', async () => {
        User.findOne.mockResolvedValue(null);
        bcrypt.hash.mockResolvedValue('hashed');
        User.create.mockResolvedValue({ _id: '42', name: 'Ana', email: 'ana@test.com' });
        fetch.mockResolvedValue({ ok: true });
        const res = mockRes();

        await controller.register(req(), res);

        expect(bcrypt.hash).toHaveBeenCalledWith('secreta', 10);
        expect(fetch).toHaveBeenCalledWith(
            'http://user-service:5003/users',
            expect.objectContaining({ method: 'POST' })
        );
        expect(res.status).toHaveBeenCalledWith(201);
        expect(res.json).toHaveBeenCalledWith({
            message: 'Usuario registrado correctamente',
            userId: '42',
        });
    });

    it('devuelve 201 aunque la sincronización responda no-ok', async () => {
        User.findOne.mockResolvedValue(null);
        bcrypt.hash.mockResolvedValue('hashed');
        User.create.mockResolvedValue({ _id: '42', name: 'Ana', email: 'ana@test.com' });
        fetch.mockResolvedValue({ ok: false });
        const res = mockRes();

        await controller.register(req(), res);

        expect(console.warn).toHaveBeenCalled();
        expect(res.status).toHaveBeenCalledWith(201);
    });

    it('devuelve 201 aunque la sincronización lance un error de red', async () => {
        User.findOne.mockResolvedValue(null);
        bcrypt.hash.mockResolvedValue('hashed');
        User.create.mockResolvedValue({ _id: '42', name: 'Ana', email: 'ana@test.com' });
        fetch.mockRejectedValue(new Error('ECONNREFUSED'));
        const res = mockRes();

        await controller.register(req(), res);

        expect(console.error).toHaveBeenCalled();
        expect(res.status).toHaveBeenCalledWith(201);
    });

    it('devuelve 500 si falla la consulta a la base de datos', async () => {
        User.findOne.mockRejectedValue(new Error('db down'));
        const res = mockRes();

        await controller.register(req(), res);

        expect(res.status).toHaveBeenCalledWith(500);
        expect(res.json).toHaveBeenCalledWith({ error: 'Error en el servidor' });
    });
});

describe('login', () => {
    const req = () => ({
        body: { email: 'ana@test.com', password: 'secreta' },
    });

    it('devuelve 404 si el usuario no existe', async () => {
        User.findOne.mockResolvedValue(null);
        const res = mockRes();

        await controller.login(req(), res);

        expect(res.status).toHaveBeenCalledWith(404);
        expect(res.json).toHaveBeenCalledWith({ message: 'Usuario no encontrado' });
    });

    it('devuelve 401 si la contraseña es incorrecta', async () => {
        User.findOne.mockResolvedValue({ _id: '1', password: 'hashed' });
        bcrypt.compare.mockResolvedValue(false);
        const res = mockRes();

        await controller.login(req(), res);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(res.json).toHaveBeenCalledWith({ message: 'Contraseña incorrecta' });
    });

    it('devuelve token y datos del usuario cuando las credenciales son válidas', async () => {
        User.findOne.mockResolvedValue({
            _id: '1',
            name: 'Ana',
            email: 'ana@test.com',
            password: 'hashed',
        });
        bcrypt.compare.mockResolvedValue(true);
        jwt.sign.mockReturnValue('jwt-token');
        const res = mockRes();

        await controller.login(req(), res);

        expect(jwt.sign).toHaveBeenCalled();
        expect(res.json).toHaveBeenCalledWith({
            token: 'jwt-token',
            user: { id: '1', name: 'Ana', email: 'ana@test.com' },
        });
    });

    it('devuelve 500 si ocurre un error inesperado', async () => {
        User.findOne.mockRejectedValue(new Error('db down'));
        const res = mockRes();

        await controller.login(req(), res);

        expect(res.status).toHaveBeenCalledWith(500);
        expect(res.json).toHaveBeenCalledWith({ error: 'Error en el servidor' });
    });
});

describe('me', () => {
    it('devuelve 401 si no hay header Authorization', async () => {
        const res = mockRes();

        await controller.me({ headers: {} }, res);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(res.json).toHaveBeenCalledWith({ message: 'No autorizado' });
    });

    it('devuelve el usuario cuando el token es válido', async () => {
        jwt.verify.mockReturnValue({ userId: '1' });
        const user = { _id: '1', name: 'Ana', email: 'ana@test.com' };
        User.findById.mockReturnValue({ select: jest.fn().mockResolvedValue(user) });
        const res = mockRes();

        await controller.me({ headers: { authorization: 'Bearer token' } }, res);

        expect(res.json).toHaveBeenCalledWith(user);
    });

    it('devuelve 404 si el usuario no existe', async () => {
        jwt.verify.mockReturnValue({ userId: '1' });
        User.findById.mockReturnValue({ select: jest.fn().mockResolvedValue(null) });
        const res = mockRes();

        await controller.me({ headers: { authorization: 'Bearer token' } }, res);

        expect(res.status).toHaveBeenCalledWith(404);
        expect(res.json).toHaveBeenCalledWith({ message: 'Usuario no encontrado' });
    });

    it('devuelve 401 si el token es inválido', async () => {
        jwt.verify.mockImplementation(() => {
            throw new Error('invalid token');
        });
        const res = mockRes();

        await controller.me({ headers: { authorization: 'Bearer token-malo' } }, res);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(res.json).toHaveBeenCalledWith({ message: 'Token inválido' });
    });
});
