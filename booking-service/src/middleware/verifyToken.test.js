const jwt = require('jsonwebtoken');
const verifyToken = require('./verifyToken');

jest.mock('jsonwebtoken');

const mockRes = () => {
    const res = {};
    res.status = jest.fn().mockReturnValue(res);
    res.json = jest.fn().mockReturnValue(res);
    return res;
};

describe('verifyToken middleware', () => {
    const OLD_ENV = process.env;

    beforeEach(() => {
        jest.clearAllMocks();
        process.env = { ...OLD_ENV, JWT_SECRET: 'test-secret' };
    });

    afterAll(() => {
        process.env = OLD_ENV;
    });

    it('responde 401 cuando no hay header Authorization', () => {
        const req = { headers: {} };
        const res = mockRes();
        const next = jest.fn();

        verifyToken(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(res.json).toHaveBeenCalledWith({ message: 'Token no proporcionado' });
        expect(next).not.toHaveBeenCalled();
    });

    it('responde 401 cuando el header no empieza con "Bearer "', () => {
        const req = { headers: { authorization: 'Basic abc123' } };
        const res = mockRes();
        const next = jest.fn();

        verifyToken(req, res, next);

        expect(res.status).toHaveBeenCalledWith(401);
        expect(res.json).toHaveBeenCalledWith({ message: 'Token no proporcionado' });
        expect(next).not.toHaveBeenCalled();
    });

    it('responde 403 cuando el token es inválido', () => {
        jwt.verify.mockImplementation(() => {
            throw new Error('invalid token');
        });
        const req = { headers: { authorization: 'Bearer token-malo' } };
        const res = mockRes();
        const next = jest.fn();

        verifyToken(req, res, next);

        expect(jwt.verify).toHaveBeenCalledWith('token-malo', 'test-secret');
        expect(res.status).toHaveBeenCalledWith(403);
        expect(res.json).toHaveBeenCalledWith({ message: 'Token inválido' });
        expect(next).not.toHaveBeenCalled();
    });

    it('adjunta req.user y llama a next() cuando el token es válido', () => {
        const decoded = { userId: '123', email: 'user@test.com' };
        jwt.verify.mockReturnValue(decoded);
        const req = { headers: { authorization: 'Bearer token-bueno' } };
        const res = mockRes();
        const next = jest.fn();

        verifyToken(req, res, next);

        expect(jwt.verify).toHaveBeenCalledWith('token-bueno', 'test-secret');
        expect(req.user).toEqual(decoded);
        expect(next).toHaveBeenCalledTimes(1);
        expect(res.status).not.toHaveBeenCalled();
    });
});
